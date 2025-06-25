#!/usr/bin/env bash
set -Eeuo pipefail

########################################################################
#  install.sh                                                         #
#                                                                      #
#  1) clones (or updates) the AutoGenesis repo,                        #
#  2) sources your .env,                                               
#  3) runs host prep + Ollama bootstrap,                               #
#  4) runs the main autogen.sh installer,                              #
#  5) reloads & enables the autogen systemd service.                  #
########################################################################

# Adjust these if your repo lives elsewhere
REPO_URL="https://github.com/pi0n00r/AutoGenesis.git"
BRANCH="${BRANCH:-patch-1}"       # override via env if you need another branch
WORKDIR="${WORKDIR:-$PWD/AutoGenesis}"

log()   { echo "[INSTALL][INFO]  $*"; }
error() { echo "[INSTALL][ERROR] $*" >&2; exit 1; }

# 1) Clone or update
if [[ -d "$WORKDIR/.git" ]]; then
  log "Updating existing repo in $WORKDIR…"
  git -C "$WORKDIR" fetch origin "$BRANCH"
  git -C "$WORKDIR" checkout "$BRANCH"
  git -C "$WORKDIR" pull --ff-only origin "$BRANCH"
else
  log "Cloning $REPO_URL ($BRANCH) into $WORKDIR…"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$WORKDIR" \
    || error "git clone failed"
fi

cd "$WORKDIR"

# 2) Ensure .env is present
ENV_FILE="$PWD/.env"
[[ -f "$ENV_FILE" ]] || error "Missing .env file in $WORKDIR"
# shellcheck disable=SC1090
source "$ENV_FILE"
log "Loaded configuration from .env"

# 3) Host prep & Ollama (requires sudo)
if [[ -x host_and_ollama_setup.sh ]]; then
  log "Running host + Ollama setup…"
  sudo bash host_and_ollama_setup.sh || error "host_and_ollama_setup.sh failed"
else
  error "host_and_ollama_setup.sh not found or not executable"
fi

# 4) Main autogen install (also requires sudo for DB + systemd)
if [[ -x autogen.sh ]]; then
  log "Running autogen.sh installer…"
  sudo bash autogen.sh -y || error "autogen.sh failed"
else
  error "autogen.sh not found or not executable"
fi

# 5) Enable & start the systemd unit (templated by autogen.sh)
SERVICE="autogen@${SUDO_USER:-$USER}.service"
log "Reloading systemd and enabling $SERVICE…"
sudo systemctl daemon-reload
sudo systemctl enable --now "$SERVICE" || error "Failed to enable $SERVICE"

log "All done! 🎉"
