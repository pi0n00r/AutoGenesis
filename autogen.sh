#!/usr/bin/env bash
###############################################################################
#  AUTOGENESIS – AutoGen Studio v1.4                                         #
#  Fully-rewritten installer with cohesive functions and robust error traps  #
###############################################################################

set -Eeuo pipefail
shopt -s inherit_errexit lastpipe

###############################################################################
#  Global constants                                                          #
###############################################################################
readonly SCRIPT_NAME="${0##*/}"
readonly LOG_FILE="/var/log/autogenstudio/${SCRIPT_NAME%.sh}.log"
readonly COLOR_RESET=$'\e[0m'
readonly RED=$'\e[31m'
readonly YELLOW=$'\e[33m'
readonly GREEN=$'\e[32m'

# Packages required for a minimal install (additional ones are handled later)
readonly BASE_PACKAGES=(
  python3 python3-venv python3-pip python3-dev build-essential
  openssl libpq-dev postgresql postgresql-contrib
  acl curl ca-certificates gnupg jq iproute2 nftables unzip
)
# Mapping: command ➜ package   (auto-install missing cmds)
declare -Ar CMD_TO_PKG=(
  [setfacl]=acl
  [nft]=nftables
)

###############################################################################
#  Globals that may change at runtime                                        #
###############################################################################
DRY_RUN=false
START_DAEMON=false
OLLAMA_API_URL=""            # may be provided via CLI or discovered later
OLLAMA_API_URL_CMDLINE=false  # flag – whether user specified --ollama-url
OLLAMA_VERSION="${OLLAMA_VERSION:-v0.6.2}"
TARGET_USER=""
TARGET_HOME=""
VENV_DIR=""
APPDIR=""
ENV_FILE=""

###############################################################################
#  Logging                                                                   #
###############################################################################
mkdir -p "$(dirname "$LOG_FILE")"

_log()   { printf '%s %b[INFO ]%b  %s\n'  "$(date +'%F %T')" "$GREEN"  "$COLOR_RESET" "$*" | tee -a "$LOG_FILE"; }
_warn()  { printf '%s %b[WARN ]%b  %s\n'  "$(date +'%F %T')" "$YELLOW" "$COLOR_RESET" "$*" | tee -a "$LOG_FILE"; }
_error() { printf '%s %b[ERROR]%b %s\n' "$(date +'%F %T')" "$RED"    "$COLOR_RESET" "$*" | tee -a "$LOG_FILE" >&2; }

run_cmd() {
  # Executes the command passed as a single string argument in a subshell.
  # Logs output and aborts on failure thanks to `set -e`.
  if [[ $DRY_RUN == true ]]; then
    printf 'DRY-RUN> %s\n' "$1" | tee -a "$LOG_FILE"
  else
    # shellcheck disable=SC2086,SC2090
    bash -c "$1" 2>&1 | tee -a "$LOG_FILE"
  fi
}

###############################################################################
#  Error & exit handling                                                     #
###############################################################################
trap 'rc=$?; _error "at line $LINENO: \"$BASH_COMMAND\" (exit $rc)"' ERR
trap '_log "✔ Completed $SCRIPT_NAME"' EXIT

###############################################################################
#  Helper: show usage                                                        #
###############################################################################
usage() {
  cat <<USAGE
Usage: sudo $SCRIPT_NAME [OPTIONS]
  -n, --dry-run        Show what would happen, perform no changes
  -d, --daemon         Start AutoGen Studio immediately after install
  --ollama-url URL     Use an external Ollama endpoint (skip local install)
  -h, --help           Display this help text and exit
USAGE
}

###############################################################################
#  Helper: apt utilities                                                     #
###############################################################################
apt_updated=false
_apt_update() {
  if [[ $apt_updated == false ]]; then
    run_cmd "DEBIAN_FRONTEND=noninteractive apt-get -qq update"
    apt_updated=true
  fi
}

ensure_pkg() {
  dpkg -s "$1" &>/dev/null && return 0
  _apt_update
  run_cmd "DEBIAN_FRONTEND=noninteractive apt-get -qq install -y $1"
}

require_cmd() {
  command -v "$1" &>/dev/null && return 0
  if [[ -n ${CMD_TO_PKG[$1]:-} ]]; then
    _log "Installing package ${CMD_TO_PKG[$1]} for missing command $1"
    ensure_pkg "${CMD_TO_PKG[$1]}"
  fi
  command -v "$1" &>/dev/null || { _error "$1 still missing after install"; exit 1; }
}

###############################################################################
#  Step helpers                                                              #
###############################################################################
ensure_base_packages() {
  if [[ $DRY_RUN != true ]]; then export DEBIAN_FRONTEND=noninteractive; fi
  for pkg in "${BASE_PACKAGES[@]}"; do
    ensure_pkg "$pkg"
  done
  run_cmd "systemctl enable --now postgresql"
  run_cmd "systemctl enable --now nftables"
}

parse_cli() {
  local PARSED
  PARSED=$(getopt -o ndh -l dry-run,daemon,help,ollama-url: -- "$@") || { usage; exit 1; }
  eval set -- "$PARSED"
  while true; do
    case $1 in
      -n|--dry-run)  DRY_RUN=true; shift;;
      -d|--daemon)   START_DAEMON=true; shift;;
      --ollama-url)  OLLAMA_API_URL="$2"; OLLAMA_API_URL_CMDLINE=true; shift 2;;
      -h|--help)     usage; exit 0;;
      --) shift; break;;
    esac
  done
}

detect_target_user() {
  [[ $EUID -eq 0 ]] || { _error "Run with sudo/root."; exit 1; }
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    TARGET_USER=$SUDO_USER
  else
    _error "Cannot determine non-root user (SUDO_USER unset)"; exit 1
  fi
  TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
  VENV_DIR="$TARGET_HOME/autogen"
  APPDIR="$TARGET_HOME/.autogenstudio"
  ENV_FILE="$VENV_DIR/.env"
}

load_or_create_env() {
  # shellcheck disable=SC2154  # AUTOGEN_DB_USER appears later via sourced .env or new gens
  if [[ -f $ENV_FILE ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    _log "Loaded existing environment file $ENV_FILE"
  else
    _warn "No .env found – will generate a new one later"
  fi
}

validate_env() {
  # true (0)  if file is valid, false (1) otherwise
  [[ -f $1 ]] || return 1
  ! grep -vE '^\s*(#|$)' "$1" | grep -qvE '^[A-Za-z_][A-Za-z0-9_]*=.*$'
}

setup_postgres() {
  local DB_PASS AUTOGEN_DB_USER AUTOGEN_DB_NAME
  AUTOGEN_DB_USER=${AUTOGEN_DB_USER:-autogen}
  AUTOGEN_DB_NAME=${AUTOGEN_DB_NAME:-autogen}
  DB_PASS=${AUTOGEN_DB_PASS:-$(openssl rand -hex 12)}

  role_exists()   { sudo -u postgres psql -tAqc "SELECT 1 FROM pg_roles    WHERE rolname='${AUTOGEN_DB_USER}'"; }
  db_exists()     { sudo -u postgres psql -tAqc "SELECT 1 FROM pg_database WHERE datname='${AUTOGEN_DB_NAME}'"; }

  if ! role_exists | grep -q 1; then
    run_cmd "sudo -u postgres psql -qc \"CREATE USER ${AUTOGEN_DB_USER} PASSWORD '${DB_PASS}';\""
  fi
  if ! db_exists | grep -q 1; then
    run_cmd "sudo -u postgres createdb -O ${AUTOGEN_DB_USER} ${AUTOGEN_DB_NAME}"
  fi

  local PG_HBA
  PG_HBA=$(sudo -u postgres psql -tAqc 'SHOW hba_file;')
  if ! grep -qE "^\s*local\s+all\s+${AUTOGEN_DB_USER}" "$PG_HBA"; then
    _log "Patching pg_hba for user $AUTOGEN_DB_USER"
    run_cmd "sudo awk -v user=${AUTOGEN_DB_USER} 'BEGIN{done=0} /^\\s*local\\s+/ && !done{print \"local   all   \" user \"   scram-sha-256\"; done=1} {print}' $PG_HBA > $PG_HBA.tmp"
    run_cmd "sudo mv $PG_HBA.tmp $PG_HBA"
    run_cmd "systemctl reload postgresql"
  fi

  # Export for later env-file generation
  export AUTOGEN_DB_USER AUTOGEN_DB_NAME DB_PASS
}

setup_python() {
  if [[ ! -f $VENV_DIR/bin/activate ]]; then
    run_cmd "sudo -u $TARGET_USER python3 -m venv $VENV_DIR"
  fi
  run_cmd "sudo -u $TARGET_USER $VENV_DIR/bin/pip install --quiet --upgrade pip"
  run_cmd "sudo -u $TARGET_USER $VENV_DIR/bin/pip install --quiet autogenstudio 'autogen-ext[ollama]' 'autogen-ext[web-surfer]' psycopg[binary] playwright"
  run_cmd "sudo -u $TARGET_USER $VENV_DIR/bin/python -m playwright install chromium --with-deps"
  run_cmd "chown -R $TARGET_USER:$TARGET_USER $VENV_DIR $APPDIR || true"   # tolerate if APPDIR absent
}

regenerate_env_file() {
  local regen=false
  if [[ ! -f $ENV_FILE ]] || ! validate_env "$ENV_FILE"; then regen=true; fi
  if [[ $regen == true ]]; then
    _log "(Re)generating environment file $ENV_FILE"
    local PASS_URI
    PASS_URI=$(jq -rn --arg v "$DB_PASS" '$v|@uri')
    cat >"$ENV_FILE" <<EOF
# Auto-generated by $SCRIPT_NAME on $(date +%F)
LOG_FILE="$LOG_FILE"
AUTOGEN_DB_USER="$AUTOGEN_DB_USER"
AUTOGEN_DB_NAME="$AUTOGEN_DB_NAME"
AUTOGEN_DB_PASS="$DB_PASS"
DATABASE_URL="postgresql+psycopg://${AUTOGEN_DB_USER}:${PASS_URI}@localhost/${AUTOGEN_DB_NAME}"
OLLAMA_API_URL="${OLLAMA_API_URL:-http://localhost:11434}"
OLLAMA_VERSION="$OLLAMA_VERSION"
DRY_RUN="$DRY_RUN"
EOF
    run_cmd "chown $TARGET_USER:$TARGET_USER $ENV_FILE"
    run_cmd "chmod 600 $ENV_FILE"
  fi
}

setup_nftables() {
  require_cmd nft
  run_cmd "mkdir -p /etc/nftables.d"
  local NFTA_SNIPPET='/etc/nftables.d/autogen.nft'
  if [[ ! -f $NFTA_SNIPPET ]]; then
    cat >"$NFTA_SNIPPET" <<'EOF'
table inet filter {
  chain input {
    type filter hook input priority 0;
    ct state established,related accept
    iif lo accept
    tcp dport { 3000, 11434 } accept
  }
}
EOF
    run_cmd "chmod 640 $NFTA_SNIPPET"
    grep -q autogen.nft /etc/nftables.conf 2>/dev/null \
      || run_cmd bash -c "echo include \${NFTA_SNIPPET} >> /etc/nftables.conf"
    run_cmd "nft -f /etc/nftables.conf"
  fi
}

probe_ollama() {
  curl -fsSL --max-time 5 "$1/api/tags" &>/dev/null
}

install_local_ollama() {
  command -v ollama &>/dev/null && return 0
  local zip="ollama-portable-${OLLAMA_VERSION}-linux.zip"
  local url="https://github.com/ollama/ollama/releases/download/${OLLAMA_VERSION}/${zip}"
  local sha_url="${url}.sha256"

  _log "Downloading Ollama ${OLLAMA_VERSION}"
  run_cmd "curl -fsSL $sha_url -o /tmp/ollama.sha256"
  run_cmd "curl -fsSL $url -o /tmp/ollama.zip"
  run_cmd "(cd /tmp && sha256sum -c ollama.sha256)"
  run_cmd "mkdir -p /usr/local/bin/ollama-bin"
  run_cmd "unzip -q /tmp/ollama.zip -d /usr/local/bin/ollama-bin"
  run_cmd "ln -sf /usr/local/bin/ollama-bin/ollama /usr/local/bin/ollama"
  run_cmd "rm /tmp/ollama.zip /tmp/ollama.sha256"
  run_cmd "chmod +x /usr/local/bin/ollama"
}

setup_ollama() {
  [[ -z $OLLAMA_API_URL ]] && OLLAMA_API_URL="http://localhost:11434"

  if [[ $OLLAMA_API_URL_CMDLINE == true ]]; then
    probe_ollama "$OLLAMA_API_URL" || { _error "Provided --ollama-url unreachable"; exit 1; }
    return 0
  fi

  if ! probe_ollama "$OLLAMA_API_URL"; then
    install_local_ollama

    local INTEL_VARS=""
    if [[ -c /dev/dri/renderD128 || -d /sys/class/drm/card0 ]]; then
      INTEL_VARS=$'Environment="ONEAPI_DEVICE_SELECTOR=level_zero:0"\nEnvironment="OLLAMA_NUM_GPU=999"\nEnvironment="SYCL_CACHE_PERSISTENT=1"'
      _log "Intel GPU detected – enabling Level-Zero acceleration"
    else
      _warn "No Intel GPU found; Ollama will run on CPU"
    fi

    local UNIT_O=/etc/systemd/system/ollama-intel.service
    if [[ ! -f $UNIT_O ]]; then
      cat >"$UNIT_O" <<EOF
[Unit]
Description=Ollama (Intel-GPU portable build)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/ollama serve --host 0.0.0.0
Restart=on-failure
RestartSec=3
${INTEL_VARS}

[Install]
WantedBy=multi-user.target
EOF
    elif [[ -n $INTEL_VARS && ! grep -q ONEAPI_DEVICE_SELECTOR "$UNIT_O" ]]; then
      run_cmd "sed -i '/^RestartSec/a ${INTEL_VARS//$'\n'/\\n}' $UNIT_O"
    fi

    run_cmd "systemctl daemon-reload"
    run_cmd "systemctl enable --now ollama-intel.service"
  fi

  # Give local instance up to 60 s to start
  for i in {1..60}; do
    if probe_ollama "$OLLAMA_API_URL"; then break; fi
    [[ $i -eq 60 ]] && { _error "Ollama failed to become ready"; exit 1; }
    sleep 1
  done
}

setup_autogen_unit() {
  local UNIT_FILE='/etc/systemd/system/autogenstudio@.service'
  if [[ ! -f $UNIT_FILE ]]; then
    cat >"$UNIT_FILE" <<'EOF'
[Unit]
Description=AutoGen Studio (%i)
After=network.target postgresql.service ollama-intel.service

[Service]
Type=simple
User=%i
EnvironmentFile=%h/autogen/.env
ExecStart=%h/autogen/bin/autogenstudio ui --host 0.0.0.0 --port 3000 \
          --appdir %h/.autogenstudio --database-uri ${DATABASE_URL} --upgrade-database
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    run_cmd "systemctl daemon-reload"
  fi

  # Ensure postgres can traverse the user's home for DB socket if needed
  require_cmd setfacl
  if ! sudo -u postgres test -x "$TARGET_HOME"; then
    run_cmd "setfacl -m u:postgres:--x $TARGET_HOME"
  fi

  run_cmd "systemctl enable autogenstudio@$TARGET_USER"
  [[ $START_DAEMON == true ]] && run_cmd "systemctl restart autogenstudio@$TARGET_USER"
}

print_final_message() {
  local ip
  ip=$(hostname -I | awk '{print $1}')
  _log "✔ Installation finished – Studio at http://${ip}:3000"
  [[ $DRY_RUN == true ]] && _warn "Dry-run mode: no changes were applied."
}

###############################################################################
#  Main                                                                      #
###############################################################################
main() {
  parse_cli "$@"
  detect_target_user
  ensure_base_packages
  load_or_create_env
  setup_postgres
  setup_python
  regenerate_env_file
  setup_nftables
  setup_ollama
  setup_autogen_unit
  print_final_message
}

main "$@"

