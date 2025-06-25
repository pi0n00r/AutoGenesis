#!/usr/bin/env bash
###############################################################################
#   AUTOGENESIS – AutoGen Studio v1.4-intel  (Intel-GPU, no Docker)           #
###############################################################################
set -Eeuo pipefail
shopt -s inherit_errexit lastpipe
trap 'rc=$?; echo "$(date +'%F %T') [ERROR] at line $LINENO: \"$BASH_COMMAND\" (exit $rc)" | tee -a /var/log/autogen_setup.log >&2' ERR
cd /   # NOTHING before this (avoids dpkg-hook “Permission denied”)

#######################################  constants & colours  #################
readonly SCRIPT_NAME="${0##*/}"
readonly DEF_DB_USER="${AUTOGEN_DB_USER:-autogen_user}"
readonly DEF_DB_NAME="${AUTOGEN_DB_NAME:-autogen}"
readonly LOG_FILE="/var/log/autogen_setup.log"
readonly COLOR_RESET=$'\e[0m'; readonly RED=$'\e[31m'; readonly YELLOW=$'\e[33m'; readonly GREEN=$'\e[32m'

#######################################  mutable globals  #####################
ASSUME_YES=false DRY_RUN=false START_DAEMON=false
OLLAMA_VERSION="${OLLAMA_VERSION:-v0.6.2}"
OLLAMA_API_URL="${OLLAMA_API_URL:-}"
TARGET_USER='' TARGET_HOME='' VENV_DIR='' APPDIR='' ENV_FILE=''

#######################################  logging helpers  #####################
log()   { printf '%s %b[INFO ]%b  %s\n'  "$(date +'%F %T')" "$GREEN"  "$COLOR_RESET" "$*" | tee -a "$LOG_FILE"; }
warn()  { printf '%s %b[WARN ]%b  %s\n'  "$(date +'%F %T')" "$YELLOW" "$COLOR_RESET" "$*" | tee -a "$LOG_FILE"; }
error() { printf '%s %b[ERROR]%b %s\n'   "$(date +'%F %T')" "$RED"    "$COLOR_RESET" "$*" | tee -a "$LOG_FILE" >&2; }

#######################################  helpers  #############################
run_cmd() { $DRY_RUN && { printf 'DRY-RUN: %q\n' "$*"; return; }; eval "$@"; }
usage() { cat <<USAGE
Usage: sudo $SCRIPT_NAME [OPTIONS]
  -y, --assume-yes     Non-interactive (accept defaults)
  -n, --dry-run        Show what would happen, change nothing
  -d, --daemon         Start Studio immediately (systemd always installed)
      --ollama-url URL Use an external Ollama endpoint (skip local install)
  -h, --help           This help text
USAGE
}

#######################################  cli parsing  #########################
PARSED=$(getopt -o yndh -l assume-yes,dry-run,daemon,help,ollama-url: -- "$@") || { usage; exit 1; }
eval set -- "$PARSED"
while true; do
  case $1 in
    -y|--assume-yes) ASSUME_YES=true ;;
    -n|--dry-run)    DRY_RUN=true ;;
    -d|--daemon)     START_DAEMON=true ;;
    --ollama-url)    OLLAMA_API_URL=$2; shift ;;
    -h|--help)       usage; exit 0 ;;
    --) shift; break ;;
  esac; shift; done

#######################################  pre-flight  ##########################
[[ $EUID -eq 0 ]] || { error "Run with sudo/root."; exit 1; }

if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
  TARGET_USER=$SUDO_USER
elif id -u pi &>/dev/null; then
  TARGET_USER=pi
else
  error "Cannot determine non-root user"; exit 1
fi
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)

VENV_DIR="$TARGET_HOME/autogen"
APPDIR="$TARGET_HOME/.autogenstudio"
ENV_FILE="$VENV_DIR/.env"
mkdir -p "$APPDIR" "${LOG_FILE%/*}"

###############################################################################
# 0) GPU host-prep  ── repo + runtime for Intel • NVIDIA • AMD • CPU-only
###############################################################################
log "➜ Detecting GPU(s) and preparing vendor repos/runtimes …"

detect_gpus() {                       # returns 0-3 tokens
  local pci; pci=$(lspci -nnk | grep -E 'VGA|3D|Display' || true)
  [[ $pci =~ Intel|i915 ]]   && echo intel
  [[ $pci =~ NVIDIA ]]       && echo nvidia
  [[ $pci =~ AMD|Radeon ]]   && echo amd
}

# -- helpers --------------------------------------------------------------- #
add_apt_component() {                 # ensure a sources.list has component
  local comp=$1
  grep -Eqs "^[^#].*\s$comp(\s|$)" /etc/apt/sources.list && return
  log "  • Enabling APT component: $comp"
  run_cmd sed -i "s/ main/ main $comp/" /etc/apt/sources.list
  apt_updated=false
}

add_repo_intel() {
  local file=/etc/apt/sources.list.d/intel-gpu.list
  [[ -f $file ]] && return
  log "  • Adding Intel Graphics (oneAPI) repo"
  run_cmd install -d -m 0755 /etc/apt/keyrings
  run_cmd curl -fsSL https://repositories.intel.com/graphics/intel-graphics.key \
        -o /etc/apt/keyrings/intel.asc
  run_cmd chmod a+r /etc/apt/keyrings/intel.asc
  run_cmd bash -c \
    "echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/intel.asc] \
https://repositories.intel.com/graphics/ all main' > $file"
  apt_updated=false
}

add_repo_nvidia() {
  local codename arch list gpg url_base
  codename=$( . /etc/os-release && echo $VERSION_CODENAME )
  arch=$(dpkg --print-architecture)
  list=/etc/apt/sources.list.d/nvidia-cuda.list
  [[ -f $list ]] && return
  log "  • Adding NVIDIA CUDA repo"
  url_base="https://developer.download.nvidia.com/compute/cuda/repos/$codename/$arch"
  run_cmd install -d -m 0755 /etc/apt/keyrings
  run_cmd curl -fsSL "$url_base/3bf863cc.pub" \
        -o /etc/apt/keyrings/nvidia.asc
  run_cmd chmod a+r /etc/apt/keyrings/nvidia.asc
  run_cmd bash -c \
    "echo 'deb [arch=$arch signed-by=/etc/apt/keyrings/nvidia.asc] $url_base /' > $list"
  apt_updated=false
}

add_repo_amd() {
  local file=/etc/apt/sources.list.d/rocm.list
  [[ -f $file ]] && return
  log "  • Adding AMD ROCm repo"
  run_cmd install -d -m 0755 /etc/apt/keyrings
  run_cmd curl -fsSL https://repo.radeon.com/rocm/rocm.gpg.key \
        -o /etc/apt/keyrings/rocm.asc
  run_cmd chmod a+r /etc/apt/keyrings/rocm.asc
  run_cmd bash -c \
    "echo 'deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/rocm.asc] \
https://repo.radeon.com/rocm/apt/debian/ $( . /etc/os-release && echo $VERSION_CODENAME ) main' > $file"
  apt_updated=false
}

# -- main ------------------------------------------------------------------ #
GPU_LIST=($(detect_gpus))
[[ ${#GPU_LIST[@]} -eq 0 ]] && GPU_LIST=(cpu)

# Make sure non-free components are on so drivers are visible
for c in contrib non-free non-free-firmware; do add_apt_component "$c"; done

# Add vendor repos (if needed)
for v in "${GPU_LIST[@]}"; do
  case $v in
    intel)  add_repo_intel  ;;
    nvidia) add_repo_nvidia ;;
    amd)    add_repo_amd    ;;
  esac
done

# Package lists per vendor
declare -A GPU_PKGS
GPU_PKGS[intel]="intel-media-va-driver-non-free intel-opencl-icd intel-level-zero-gpu libmfx1 vainfo clinfo"
GPU_PKGS[nvidia]="cuda-drivers nvidia-compute-utils nvidia-opencl-dev nvidia-smi"
GPU_PKGS[amd]="rocm-opencl-runtime mesa-opencl-icd rocm-smi-lib64 vainfo clinfo"
GPU_PKGS[cpu]="vainfo clinfo"

for v in "${GPU_LIST[@]}"; do
  log "  • Installing $v runtime packages"
  for p in ${GPU_PKGS[$v]}; do ensure_pkg "$p"; done
done

log "Adding $TARGET_USER to render,video groups"
run_cmd usermod -aG render,video "$TARGET_USER"

# Optional vendor-specific tweaks (harmless if they fail)
if [[ " ${GPU_LIST[*]} " == *" nvidia "* && ! $DRY_RUN ]]; then
  nvidia-smi -pm 1 || warn "Could not set NVIDIA persistence mode (non-fatal)"
fi
if [[ " ${GPU_LIST[*]} " == *" amd "* && ! $DRY_RUN ]]; then
  run_cmd udevadm control --reload-rules
  run_cmd udevadm trigger
fi

log "GPU host-prep complete: detected → ${GPU_LIST[*]}"

###############################################################################
# 1) base packages + self-healing helpers
###############################################################################
readonly PKGS=(
  python3 python3-venv python3-pip python3-dev build-essential
  openssl libpq-dev postgresql postgresql-contrib acl
  curl ca-certificates gnupg jq iproute2 nftables unzip
)

declare -A CMD_PKG=( [setfacl]=acl [nft]=nftables )

apt_updated=false
_apt_update() { $apt_updated || { run_cmd DEBIAN_FRONTEND=noninteractive apt-get -qq update; apt_updated=true; }; }
ensure_pkg() {
  dpkg -s "$1" &>/dev/null && return
  _apt_update
  run_cmd DEBIAN_FRONTEND=noninteractive apt-get -qq install -y "$1"
}
require_cmd() {
  command -v "$1" &>/dev/null && return
  [[ -n ${CMD_PKG[$1]:-} ]] && { log "Installing ${CMD_PKG[$1]} for missing $1"; ensure_pkg "${CMD_PKG[$1]}"; }
  command -v "$1" &>/dev/null || { error "$1 still missing after attempted fix"; exit 1; }
}

if ! $DRY_RUN; then export DEBIAN_FRONTEND=noninteractive; fi
for p in "${PKGS[@]}"; do ensure_pkg "$p"; done
run_cmd systemctl enable --now postgresql
run_cmd systemctl enable --now nftables            # persists firewall rules

###############################################################################
# 2) PostgreSQL role, db, and HBA fix
###############################################################################
role_exists() { sudo -u postgres psql -tAqc "SELECT 1 FROM pg_roles WHERE rolname='$DEF_DB_USER';"; }
db_exists()   { sudo -u postgres psql -tAqc "SELECT 1 FROM pg_database WHERE datname='$DEF_DB_NAME';"; }

DB_PASS="${AUTOGEN_DB_PASS:-$(openssl rand -hex 12)}"

[[ $(role_exists) == 1 ]] || run_cmd sudo -u postgres psql -qc "CREATE USER $DEF_DB_USER PASSWORD '$DB_PASS';"
[[ $(db_exists)   == 1 ]] || run_cmd sudo -u postgres createdb -O "$DEF_DB_USER" "$DEF_DB_NAME"

PG_HBA=$(sudo -u postgres psql -tAqc 'SHOW hba_file;')
if ! grep -qE "^[[:space:]]*local[[:space:]]+all[[:space:]]+$DEF_DB_USER" "$PG_HBA"; then
  run_cmd sudo awk -v user="$DEF_DB_USER" '
      BEGIN{done=0}
      /^[[:space:]]*local[[:space:]]+/ && !done{
        print "local   all   " user "   scram-sha-256"
        done=1
      }
      {print}
  ' "$PG_HBA" > "$PG_HBA.tmp"
  run_cmd sudo mv "$PG_HBA.tmp" "$PG_HBA"
  run_cmd systemctl reload postgresql
fi

###############################################################################
# 3) Python virtualenv + packages
###############################################################################
if [[ ! -f "$VENV_DIR/bin/activate" ]]; then
  run_cmd sudo -u "$TARGET_USER" python3 -m venv "$VENV_DIR"
fi
run_cmd sudo -u "$TARGET_USER" "$VENV_DIR/bin/pip" install --quiet --upgrade pip
run_cmd sudo -u "$TARGET_USER" "$VENV_DIR/bin/pip" install --quiet \
         autogenstudio "autogen-ext[ollama]" "autogen-ext[web-surfer]" psycopg[binary] playwright
run_cmd sudo -u "$TARGET_USER" "$VENV_DIR/bin/python" -m playwright install chromium --with-deps
run_cmd chown -R "$TARGET_USER:$TARGET_USER" "$VENV_DIR" "$APPDIR"

###############################################################################
# 4) .env generation (idempotent, validated)
###############################################################################
validate_env() { ! grep -vE '^\s*(#|$)' "$1" | grep -qvE '^[A-Za-z_][A-Za-z0-9_]*=.*$'; }
regen=false
[[ ! -f "$ENV_FILE" || ! $(validate_env "$ENV_FILE") ]] && regen=true

urlencode() { jq -rn --arg v "$1" '$v|@uri'; }

if $regen; then
  PASS_URI=$(urlencode "$DB_PASS")
  cat >"$ENV_FILE" <<EOF
DB_NAME=$DEF_DB_NAME
DB_USER=$DEF_DB_USER
DB_PASSWORD=$DB_PASS
DATABASE_URL=postgresql+psycopg://$DEF_DB_USER:$PASS_URI@localhost/$DEF_DB_NAME
OLLAMA_API_URL=${OLLAMA_API_URL:-http://localhost:11434}
EOF
  run_cmd chown "$TARGET_USER:$TARGET_USER" "$ENV_FILE"
  run_cmd chmod 600 "$ENV_FILE"
fi

###############################################################################
# 5) nftables snippet (ports 3000 & 11434)
###############################################################################
require_cmd nft
run_cmd mkdir -p /etc/nftables.d
NFTA_SNIPPET='/etc/nftables.d/autogen.nft'
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
  run_cmd chmod 640 "$NFTA_SNIPPET"
  grep -q autogen.nft /etc/nftables.conf 2>/dev/null ||
     run_cmd bash -c "echo 'include \"${NFTA_SNIPPET}\"' >> /etc/nftables.conf"
  run_cmd nft -f /etc/nftables.conf
fi

###############################################################################
# 6) Intel-accelerated Ollama (portable binary + systemd)
###############################################################################
probe_ollama() { curl -fsSL --max-time 5 "$1/api/tags" >/dev/null 2>&1; }

install_ollama_bin() {
  command -v ollama &>/dev/null && return 0
  local zip="ollama-portable-${OLLAMA_VERSION}-linux.zip"
  local url="https://github.com/ollama/ollama/releases/download/${OLLAMA_VERSION}/${zip}"
  local sha_url="${url}.sha256"

  log "Downloading Ollama binary & checksum"
  run_cmd curl -fsSL "$sha_url" -o /tmp/ollama.sha256
  run_cmd curl -fsSL "$url"     -o /tmp/ollama.zip

  # Verify integrity (dry-run safe)
  run_cmd "(cd /tmp && sha256sum -c ollama.sha256)"

  run_cmd mkdir -p /usr/local/bin/ollama-bin
  run_cmd unzip -q /tmp/ollama.zip -d /usr/local/bin/ollama-bin
  run_cmd ln -sf /usr/local/bin/ollama-bin/ollama /usr/local/bin/ollama
  run_cmd rm /tmp/ollama.zip /tmp/ollama.sha256
  run_cmd chmod +x /usr/local/bin/ollama
}

if [[ -z $OLLAMA_API_URL ]]; then
  OLLAMA_API_URL="http://localhost:11434"
fi

# If user explicitly provided an endpoint, only probe; abort on failure.
if [[ -n ${OLLAMA_API_URL_CMDLINE:-} ]]; then
  probe_ollama "$OLLAMA_API_URL" || { error "Provided --ollama-url unreachable"; exit 1; }
else
  # manage local instance
  if ! probe_ollama "$OLLAMA_API_URL"; then
    install_ollama_bin

    INTEL_VARS=""
    if [[ -c /dev/dri/renderD128 || -d /sys/class/drm/card0 ]]; then
      INTEL_VARS=$'Environment="ONEAPI_DEVICE_SELECTOR=level_zero:0"\nEnvironment="OLLAMA_NUM_GPU=999"\nEnvironment="SYCL_CACHE_PERSISTENT=1"'
      log "Intel GPU detected – enabling Level-Zero acceleration"
    else
      warn "No Intel GPU found; Ollama will run on CPU"
    fi

    # Create/patch systemd unit idempotently
    UNIT_O=/etc/systemd/system/ollama-intel.service
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
    elif [[ -n $INTEL_VARS && ! $(grep -q ONEAPI_DEVICE_SELECTOR "$UNIT_O") ]]; then
      # GPU appeared since last run → patch
      run_cmd sed -i "/^RestartSec/a ${INTEL_VARS//$'\n'/\\n}" "$UNIT_O"
    fi

    run_cmd systemctl daemon-reload
    run_cmd systemctl enable --now ollama-intel.service
  fi

  # wait up to 60 s (slow boxes / first-run model pull)
  for i in {1..60}; do
    probe_ollama "$OLLAMA_API_URL" && break
    [[ $i -eq 60 ]] && { error "Ollama failed to become ready"; exit 1; }
    sleep 1
  done
fi

grep -q "^OLLAMA_API_URL=$OLLAMA_API_URL" "$ENV_FILE" || \
  run_cmd sed -i "s#^OLLAMA_API_URL=.*#OLLAMA_API_URL=$OLLAMA_API_URL#" "$ENV_FILE"

###############################################################################
# 7) AutoGen Studio systemd unit
###############################################################################
UNIT_FILE='/etc/systemd/system/autogenstudio@.service'
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
  run_cmd systemctl daemon-reload
fi

###############################################################################
# 8) final ACL + service enable
###############################################################################
require_cmd setfacl
if ! sudo -u postgres test -x "$TARGET_HOME"; then
  run_cmd setfacl -m u:postgres:--x "$TARGET_HOME"
fi

run_cmd systemctl enable autogenstudio@"$TARGET_USER"
$START_DAEMON && run_cmd systemctl restart autogenstudio@"$TARGET_USER"

log "✔ Installation finished – Studio at http://$(hostname -I | awk '{print $1}'):3000"
$DRY_RUN && warn "Dry-run mode: no changes were applied."
