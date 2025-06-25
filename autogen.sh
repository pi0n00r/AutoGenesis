#!/usr/bin/env bash
# autogen.sh – install & launch AutoGen Studio on x86-64 (no Docker)

set -Eeuo pipefail
IFS=$'\n\t'

#
# — Logging
#
LOG_FILE="/var/log/autogen_setup.log"
if ! touch "$LOG_FILE" &>/dev/null; then
  LOG_FILE="$HOME/autogen/logs/autogen_setup.log"
  mkdir -p "${LOG_FILE%/*}"
  echo "[WARN] /var/log not writable — logging to $LOG_FILE"
fi
log()      { printf '%s [INFO ] %s\n'  "$(date +'%F %T')" "$*" | tee -a "$LOG_FILE"; }
log_warn() { printf '%s [WARN ] %s\n'  "$(date +'%F %T')" "$*" | tee -a "$LOG_FILE"; }
log_err()  { printf '%s [ERROR] %s\n'  "$(date +'%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }

#
# — Arg parsing
#
DAEMON=false
while [[ $# -gt 0 ]]; do
  case $1 in
    -d|--daemon) DAEMON=true ;;
    -h|--help)
      echo "Usage: sudo $0 [-d|--daemon]"
      exit 0
      ;;
    *)
      log_err "Unknown option: $1"
      exit 1
      ;;
  esac
  shift
done

#
# — Must run as root via sudo
#
if [[ $EUID -ne 0 ]]; then
  log_err "Run this script via sudo or as root."
  exit 1
fi
if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
  log_err "Please invoke under sudo from your normal user account."
  exit 1
fi

TARGET_USER="$SUDO_USER"
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
log "Installing as user: $TARGET_USER (home: $TARGET_HOME)"

#
# — Configurable vars
#
DB_NAME="autogen"
DB_USER="autogen_user"
DB_PASS=""                     # will be generated if missing
VENV_DIR="$TARGET_HOME/autogen"
ENV_FILE="$VENV_DIR/.env"
APP_LOG="/var/log/autogen_app.log"
OLLAMA_API_URL="http://localhost:11434"
OLLAMA_VERSION="${OLLAMA_VERSION:-v0.6.2}"

#
# — Trap failures
#
trap 'rc=$?; log_err "FAILED at line $LINENO: \"$BASH_COMMAND\" (exit $rc)"; exit $rc' ERR

#
# — Apt helper & install base packages
#
export DEBIAN_FRONTEND=noninteractive
apt_updated=false
ensure_pkg(){
  dpkg -s "$1" &>/dev/null && return
  $(! $apt_updated) && { log "apt update…"; apt-get -qq update; apt_updated=true; }
  log "Installing package: $1"
  apt-get -qq install -y "$1"
}
# Only what we need – no docker
PKGS=(
  python3 python3-venv python3-pip python3-dev build-essential
  openssl libpq-dev postgresql postgresql-contrib
  curl ca-certificates gnupg jq iproute2
)
for pkg in "${PKGS[@]}"; do ensure_pkg "$pkg"; done
systemctl enable --now postgresql

#
# — PostgreSQL role & database
#
role_exists(){
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$1'"
}
db_exists(){
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='$1'"
}
if [[ "$(role_exists "$DB_USER")" != "1" ]]; then
  DB_PASS="$(openssl rand -hex 12)"
  log "Creating Postgres role $DB_USER"
  sudo -u postgres psql -c "CREATE USER $DB_USER PASSWORD '$DB_PASS';"
else
  log "Postgres role $DB_USER already exists"
fi
if [[ "$(db_exists "$DB_NAME")" != "1" ]]; then
  log "Creating database $DB_NAME"
  sudo -u postgres createdb -O "$DB_USER" "$DB_NAME"
fi

#
# — Python venv & AutoGen Studio install
#
if [[ ! -f "$VENV_DIR/bin/activate" ]]; then
  sudo -u "$TARGET_USER" python3 -m venv "$VENV_DIR"
fi
install_autogen(){
  for i in 1 2 3; do
    if sudo -u "$TARGET_USER" "$VENV_DIR/bin/pip" install --upgrade pip \
         && sudo -u "$TARGET_USER" "$VENV_DIR/bin/pip" install autogenstudio psycopg[binary]; then
      return
    fi
    log_warn "pip install retry ($i/3)"
    sleep 2
  done
  log_err "Failed to install autogenstudio"
  exit 1
}
install_autogen
chown -R "$TARGET_USER:$TARGET_USER" "$VENV_DIR"

#
# — .env management
#
url_encode(){
  python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1"
}
regen=false
if [[ -f "$ENV_FILE" ]]; then
  grep -Eq '^[A-Za-z_][A-Za-z0-9_]*=' "$ENV_FILE" || regen=true
else
  regen=true
fi
if $regen; then
  log "Generating new .env"
  [[ -z "$DB_PASS" ]] && DB_PASS="$(openssl rand -hex 12)" \
    && sudo -u postgres psql -c "ALTER USER $DB_USER PASSWORD '$DB_PASS';"
  PASS_URI=$(url_encode "$DB_PASS")
  cat > "$ENV_FILE" <<EOF
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASS
DATABASE_URL=postgresql+psycopg://$DB_USER:$PASS_URI@localhost/$DB_NAME
OLLAMA_API_URL=$OLLAMA_API_URL
EOF
  chown "$TARGET_USER:$TARGET_USER" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
else
  log "Keeping existing .env"
  # reload DB_PASS if needed
  source "$ENV_FILE"
  PASS_URI=$(url_encode "$DB_PASSWORD")
  DB_PASS="$DB_PASSWORD"
fi
export DB_NAME DB_USER DB_PASSWORD DB_PASS DATABASE_URL PASS_URI

#
# — Intel‐accelerated Ollama install & serve (no Docker)
#
install_ollama_intel(){
  command -v ollama &>/dev/null && { log "Found ollama binary, skipping install"; return; }
  ZIP_FILE="ollama-portable-${OLLAMA_VERSION}-linux.zip"
  URL="https://github.com/ollama/ollama/releases/download/${OLLAMA_VERSION}/${ZIP_FILE}"
  log "Downloading Ollama ${OLLAMA_VERSION}"
  curl -fsSL "$URL" -o /tmp/ollama.zip
  mkdir -p /usr/local/bin/ollama-bin
  unzip -q /tmp/ollama.zip -d /usr/local/bin/ollama-bin
  ln -sf /usr/local/bin/ollama-bin/ollama /usr/local/bin/ollama
  rm /tmp/ollama.zip
  chmod +x /usr/local/bin/ollama
}
install_ollama_intel

# Set Intel GPU envs for SYCL/Level‐Zero acceleration
export OLLAMA_NUM_GPU=999
export ONEAPI_DEVICE_SELECTOR=level_zero:0
export SYCL_CACHE_PERSISTENT=1
export no_proxy=localhost,127.0.0.1

# Probe & auto‐launch until Ollama responds
while true; do
  log "Probing Ollama at $OLLAMA_API_URL"
  if curl -fsSL --max-time 5 "$OLLAMA_API_URL/api/tags" -o /tmp/ollama.json \
     && jq -e '.models|length>0' /tmp/ollama.json &>/dev/null; then
    sed -i "s|^OLLAMA_API_URL=.*|OLLAMA_API_URL=$OLLAMA_API_URL|" "$ENV_FILE"
    break
  else
    log_warn "Ollama not reachable; starting 'ollama serve'"
    nohup ollama serve --host 0.0.0.0 >>"$APP_LOG" 2>&1 &
    sleep 6
  fi
done

#
# — Open firewall port 3000
#
if ! iptables -C INPUT -p tcp --dport 3000 -j ACCEPT &>/dev/null; then
  iptables -I INPUT -p tcp --dport 3000 -j ACCEPT
  log "Opened TCP/3000 in firewall"
fi

#
# — Launch AutoGen Studio
#
AUTOGEN_CMD=(
  "$VENV_DIR/bin/autogenstudio" ui
  --host 0.0.0.0 --port 3000
  --appdir "$VENV_DIR" --database-uri "$DATABASE_URL"
)
log "Starting AutoGen Studio on port 3000 (daemon=$DAEMON)"
if $DAEMON; then
  nohup "${AUTOGEN_CMD[@]}" >>"$APP_LOG" 2>&1 &
  HOST_IP=$(hostname -I | awk '{print $1}')
  log "Daemonized — visit http://$HOST_IP:3000  (logs→$APP_LOG)"
else
  exec sudo -u "$TARGET_USER" -- "${AUTOGEN_CMD[@]}"
fi
