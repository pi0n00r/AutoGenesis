#!/usr/bin/env bash
set -Eeuo pipefail

### 1) CONFIGURABLES & AUTO-DETECTION ###
# you can override these in your env before calling the script:
# you can override these in your env or via -p,-g,-u flags:
INSTALL_PATH="${INSTALL_PATH:-/opt/autogen}"
INSTALL_GROUP="${INSTALL_GROUP:-autogen}"
# allow INSTALL_USER to come _only_ from env or --user; fallback to current login
INSTALL_USER="${INSTALL_USER:-$(logname 2>/dev/null || echo "$USER")}"

PARSED=$(getopt -o p:g:u: -l path:,group:,user: -- "$@")
eval set -- "$PARSED"
while true; do
  case "$1" in
    -p|--path)   INSTALL_PATH=$2; shift 2;;
    -g|--group)  INSTALL_GROUP=$2; shift 2;;
    -u|--user)   INSTALL_USER=$2; shift 2;;
    --) shift; break;;
  esac
done

ENV_FILE="$(pwd)/.env"
AUTOGEN_SH_URL="https://raw.githubusercontent.com/pi0n00r/AutoGenesis/patch-1/autogen.sh"
HOST_SETUP_URL="https://raw.githubusercontent.com/pi0n00r/AutoGenesis/patch-1/host_and_ollama_setup.sh"

log()   { echo "[install][info] $*"; }
error() { echo "[install][error] $*" >&2; exit 1; }

### 2) PRE-CHECKS ###
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root (via sudo)."
fi
if [[ ! -f "$ENV_FILE" ]]; then
  error "Missing .env in $(pwd).  Copy .env.example and customize before running."
fi

source "$ENV_FILE"
log "Loaded configuration from $ENV_FILE"

### 3) CREATE GROUP (if missing) ###
if ! getent group "$INSTALL_GROUP" >/dev/null; then
  log "Creating group '$INSTALL_GROUP'…"
  groupadd --system "$INSTALL_GROUP"
fi

### 4) PREPARE INSTALL DIRECTORY ###
log "Preparing $INSTALL_PATH (owner=$INSTALL_USER:$INSTALL_GROUP)…"
mkdir -p "$INSTALL_PATH"
chown -R "$INSTALL_USER:$INSTALL_GROUP" "$INSTALL_PATH"
# setgid + 2775 keeps group inheritance & rwx for owner/group
chmod g+s "$INSTALL_PATH"
chmod -R 2775 "$INSTALL_PATH"

### 5) FETCH UPSTREAM SCRIPTS ###
cd "$INSTALL_PATH"
log "Downloading autogen.sh…"
curl -fsSL "$AUTOGEN_SH_URL" -o autogen.sh
chmod +x autogen.sh

# only fetch host_setup if Ollama isn't already present
if ! command -v ollama >/dev/null; then
  log "Downloading host_and_ollama_setup.sh…"
  curl -fsSL "$HOST_SETUP_URL" -o host_and_ollama_setup.sh
  chmod +x host_and_ollama_setup.sh
  RUN_HOST_SETUP=true
else
  log "ollama binary found—skipping host setup."
  RUN_HOST_SETUP=false
fi

### 6) INVOKE INSTALLER ###

# preserve env via -E; -y skips interactive prompts if supported
if $RUN_HOST_SETUP; then
  log "Running host + Ollama setup…"
  sudo -E bash host_and_ollama_setup.sh || error "host setup failed"
fi
export TARGET_USER="$INSTALL_USER"
export TARGET_HOME="$INSTALL_PATH"
export VENV_DIR="$INSTALL_PATH"
export ENV_FILE="$VENV_DIR/.env"

log "Running AutoGen Studio installer…"
sudo -E bash autogen.sh \
  --user "$INSTALL_USER" \
  --dry-run \
  "$@" \
  || error "autogen.sh failed"

### 7) ENABLE & START SYSTEMD SERVICE ###
SERVICE="autogen@${INSTALL_USER}.service"
log "Reloading systemd & enabling $SERVICE…"
systemctl daemon-reload
systemctl enable --now "$SERVICE" || error "Failed to enable $SERVICE"

log "🎉 Installation complete – Studio available on port 3000"
