#!/usr/bin/env bash
###############################################################################
#                                  AUTOGENESIS                                #
# AutoGen Studio installer / launcher – Raspberry Pi OS | PostgreSQL | Ollama #
#                                      v1.0                                   #
#   • always exports DB_PASSWORD/DB_USER/DB_NAME to runtime env               #
#   • regenerates .env safely; updates DB password only when required         #
#   • ensures firewall INPUT rule for TCP/3000 (idempotent)                   #
###############################################################################

set -Eeuo pipefail
shopt -s inherit_errexit
IFS=$'\n\t'

###############################################################################
# — logging — #################################################################
###############################################################################
LOG_FILE="/var/log/autogen_setup.log"
if ! touch "$LOG_FILE" 2>/dev/null; then
  LOG_FILE="$HOME/autogen/logs/autogen_setup.log"
  mkdir -p "${LOG_FILE%/*}"
  echo "WARN: /var/log not writable – logging to $LOG_FILE"
fi
log()       { printf '%s [INFO]  %s\n'  "$(date +'%F %T')" "$*" | tee -a "$LOG_FILE"; }
log_warn()  { printf '%s [WARN]  %s\n'  "$(date +'%F %T')" "$*" | tee -a "$LOG_FILE"; }
log_error() { printf '%s [ERROR] %s\n'  "$(date +'%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }

###############################################################################
# — config vars — #############################################################
###############################################################################
DB_NAME="autogen"
DB_USER="autogen_user"
DB_PASS=""
VENV_DIR="" ENV_FILE="" APP_LOG="/var/log/autogen_app.log"
OLLAMA_API_URL="" PASS_URI=""

###############################################################################
# — error trap — ##############################################################
###############################################################################
trap 'rc=$?; ((rc==0)) && exit 0
      trap - ERR
      log_error "FAILED at line $LINENO: \"$BASH_COMMAND\" (exit $rc)"
      exit $rc' ERR

###############################################################################
# — arg parsing — #############################################################
###############################################################################
DAEMON=false
while [[ $# -gt 0 ]]; do
  case $1 in
    -d|--daemon) DAEMON=true ;;
    -h|--help)   echo "Usage: sudo $0 [-d|--daemon]"; exit 0 ;;
    *)           echo "Unknown option $1" >&2; exit 1 ;;
  esac; shift
done

###############################################################################
# — privilege / target user — #################################################
###############################################################################
[[ $EUID -eq 0 ]] || { log_error "Run with sudo/root."; exit 1; }
if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
  TARGET_USER=$SUDO_USER
elif id -u pi &>/dev/null; then
  TARGET_USER=pi
else
  log_error "Cannot determine non-root user"; exit 1
fi
TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
log "Target user: $TARGET_USER  (home: $TARGET_HOME)"

# allow postgres to traverse $TARGET_HOME
if ! sudo -u postgres test -x "$TARGET_HOME"; then
  if command -v setfacl &>/dev/null; then
    setfacl -m u:postgres:--x "$TARGET_HOME"
  else
    chmod o+X "$TARGET_HOME"
  fi
fi

VENV_DIR="$TARGET_HOME/autogen"
ENV_FILE="$VENV_DIR/.env"

###############################################################################
# — package helper — ##########################################################
###############################################################################
DEBIAN_FRONTEND=noninteractive
apt_updated=false
ensure_pkg() {
  dpkg -s "$1" &>/dev/null && return
  $apt_updated || { log "apt update…"; apt-get -qq update; apt_updated=true; }
  apt-get -qq install -y "$1" || { log_error "apt install $1 failed"; exit 1; }
}

PKGS=(python3 python3-venv python3-pip python3-dev build-essential
      openssl libpq-dev postgresql postgresql-contrib
      curl ca-certificates gnupg jq iproute2)
for p in "${PKGS[@]}"; do ensure_pkg "$p"; done
systemctl is-active --quiet postgresql || systemctl enable --now postgresql

###############################################################################
# — PostgreSQL role & DB — ####################################################
###############################################################################
role_exists() { sudo -u postgres -H psql -tAqc "SELECT 1 FROM pg_roles WHERE rolname='$1';"; }
db_exists()   { sudo -u postgres -H psql -tAqc "SELECT 1 FROM pg_database WHERE datname='$1';"; }

if [[ $(role_exists "$DB_USER") != 1 ]]; then
  DB_PASS=$(openssl rand -hex 12)
  sudo -u postgres -H psql -qc "CREATE USER $DB_USER PASSWORD '$DB_PASS';"
else
  log "Role $DB_USER exists"
fi

[[ $(db_exists "$DB_NAME") == 1 ]] || \
  { sudo -u postgres -H createdb -O "$DB_USER" "$DB_NAME"; log "Created DB $DB_NAME"; }

###############################################################################
# — virtualenv & AutoGen Studio — ############################################
###############################################################################
[[ -f "$VENV_DIR/bin/activate" ]] || sudo -u "$TARGET_USER" -H python3 -m venv "$VENV_DIR"
sudo -u "$TARGET_USER" -H "$VENV_DIR/bin/pip" -q install --upgrade pip

install_autogen() {
  for i in {1..3}; do
    sudo -u "$TARGET_USER" -H "$VENV_DIR/bin/pip" install --upgrade \
      autogenstudio psycopg[binary] && return
    log_warn "pip retry ($i/3)"; sleep 4
  done
  log_error "AutoGen Studio install failed"
}
install_autogen
chown -R "$TARGET_USER:$TARGET_USER" "$VENV_DIR"

###############################################################################
# — .env handling — ###########################################################
###############################################################################
validate_env() { grep -vE '^\s*(#|$)' "$1" | grep -qvE '^[A-Za-z_][A-Za-z0-9_]*=.*$'; }
regen=false
if [[ -f "$ENV_FILE" ]]; then
  validate_env "$ENV_FILE" || { mv "$ENV_FILE" "$ENV_FILE.bak.$(date +%s)"; regen=true; }
else regen=true; fi

url_encode(){ local o c; for ((i=0;i<${#1};i++)); do
                 c=${1:i:1}
                 [[ $c =~ [A-Za-z0-9._~-] ]] && o+="$c" || o+=$(printf '%%%02X' "'$c")
               done; printf '%s' "$o"; }

if $regen; then
  [[ -z $DB_PASS ]] && DB_PASS=$(openssl rand -hex 12)
  sudo -u postgres -H psql -qc "ALTER USER $DB_USER PASSWORD '$DB_PASS';"
  PASS_URI=$(url_encode "$DB_PASS")
  cat >"$ENV_FILE" <<EOF
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASSWORD=$DB_PASS
DATABASE_URL=postgresql+psycopg://$DB_USER:$PASS_URI@localhost/$DB_NAME
OLLAMA_API_URL=http://localhost:11434
EOF
  chown "$TARGET_USER:$TARGET_USER" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
else
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  DB_PASS="${DB_PASSWORD:-$DB_PASS}"
  PASS_URI=$(url_encode "$DB_PASS")
fi

export DATABASE_URL="postgresql+psycopg://$DB_USER:$PASS_URI@localhost/$DB_NAME"
export DB_PASSWORD="$DB_PASS" DB_USER DB_NAME
rm -f "/home/$TARGET_USER/.autogenstudio/temp_env_vars.env" || true

###############################################################################
# — Docker (for optional Ollama) — ###########################################
###############################################################################
if ! command -v docker &>/dev/null; then
  log "Installing Docker Engine"
  getent group docker >/dev/null || groupadd docker
  ensure_pkg ca-certificates; ensure_pkg curl; ensure_pkg gnupg
  install -d -m 0755 /etc/apt/keyrings
  [[ -f /etc/apt/keyrings/docker.gpg ]] || \
    curl -fsSL https://download.docker.com/linux/debian/gpg | \
      gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
  apt-get -qq update
  apt-get -qq install -y docker-ce docker-ce-cli containerd.io \
                         docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
fi
id "$TARGET_USER" | grep -qw docker || usermod -aG docker "$TARGET_USER"

###############################################################################
# — Ollama API probe — ########################################################
###############################################################################
while true; do
  read -r -p "Enter Ollama API URL [${OLLAMA_API_URL:-http://localhost:11434}]: " in </dev/tty || true
  OLLAMA_API_URL="${in:-$OLLAMA_API_URL}"; OLLAMA_API_URL="${OLLAMA_API_URL%/}"
  log "Probing Ollama @ $OLLAMA_API_URL"
  if curl -fsSL --max-time 5 "$OLLAMA_API_URL/api/tags" -o /tmp/ollama.json; then
    jq -e '.models|length>0' /tmp/ollama.json &>/dev/null && \
      { sed -i "s#^OLLAMA_API_URL=.*#OLLAMA_API_URL=$OLLAMA_API_URL#" "$ENV_FILE"; break; } \
      || log_warn "API OK but zero models"
  else
    log_warn "Cannot reach API"
    if [[ "$OLLAMA_API_URL" == "http://localhost:11434" ]]; then
      read -r -p "Install local Ollama via Docker? [y/N]: " yn </dev/tty
      [[ ${yn,,} == y ]] && \
        docker run -d --name ollama -v ollama_data:/root/.ollama \
          -p 11434:11434 ghcr.io/jmorganca/ollama:latest && sleep 6 && continue
    fi
  fi
  echo "Try another URL or Ctrl-C to abort."
done

###############################################################################
# — firewall: open port 3000 — ################################################
###############################################################################
if ! iptables -C INPUT -p tcp --dport 3000 -j ACCEPT 2>/dev/null; then
  iptables -I INPUT -p tcp --dport 3000 -j ACCEPT
  log "Opened firewall INPUT rule for TCP/3000"
fi

###############################################################################
# — launch — ##################################################################
###############################################################################
AUTOGEN_CMD=(
  "$VENV_DIR/bin/autogenstudio" ui
  --host 0.0.0.0
  --port 3000
  --appdir "$VENV_DIR"
  --database-uri "$DATABASE_URL"
)

log "Starting AutoGen Studio v1.0 on :3000 (daemon=$DAEMON)"
if $DAEMON; then
  nohup "${AUTOGEN_CMD[@]}" >>"$APP_LOG" 2>&1 &
  log "Daemonized – visit http://$(hostname -I | awk '{print $1}'):3000  (logs → $APP_LOG)"
else
  exec sudo -u "$TARGET_USER" -- "${AUTOGEN_CMD[@]}"
fi
