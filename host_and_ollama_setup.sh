#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit lastpipe

#–– Log file (must match autogen.sh) ––#
readonly LOG_FILE=/var/log/autogenstudio/autogen_setup.log
mkdir -p "$(dirname "$LOG_FILE")"

#–– Error trap writes to $LOG_FILE ––#
trap "
  rc=\$?;
  echo \"\$(date +'%F %T') [HOST_SETUP][ERROR] line \$LINENO: \\\"\$BASH_COMMAND\\\" (exit \$rc)\" \
    | tee -a \"\$LOG_FILE\" >&2
" ERR

#–– Locate this script’s directory ––#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#–– Dry‐run support ––#
DRY_RUN="${DRY_RUN:-false}"
run_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "DRY-RUN: $*"
  else
    eval "$@"
  fi
}

#–– Simple logging funcs ––#
log() { echo "$(date +'%F %T') [HOST_SETUP][INFO] $*" | tee -a "$LOG_FILE"; }
err() { echo "$(date +'%F %T') [HOST_SETUP][ERROR] $*" | tee -a "$LOG_FILE" >&2; exit 1; }

########################################
# 1) Host prep for Intel‐GPU build
########################################
REPO_URL="https://github.com/pi0n00r/self-hosted-ai-starter-kit.git"
BRANCH="compose-intel-gpu-and-build"

log "Cloning self-hosted-ai-starter-kit (branch: $BRANCH)…"
run_cmd rm -rf self-hosted-ai-starter-kit
run_cmd git clone --depth 1 --branch "$BRANCH" "$REPO_URL" || err "git clone failed"

cd self-hosted-ai-starter-kit/host-prep || err "Cannot enter host-prep directory"
log "Running host-prep.sh (GPU profile)…"
run_cmd sudo bash host-prep.sh -y --profile gpu-nvidia || err "host-prep.sh failed"
cd "$SCRIPT_DIR"

########################################
# 2) Download & launch Ollama (Intel IPEX)
########################################
IPEX_RELEASE="v0.6.2"
TMPDIR="$(mktemp -d)"
DESTDIR="/opt/ollama-ipex"

log "Downloading Ollama ${IPEX_RELEASE}…"
run_cmd curl -fsSL \
  "https://github.com/intel/ipex-llm/releases/download/${IPEX_RELEASE}/ollama_portable_linux_${IPEX_RELEASE}.tgz" \
  -o "${TMPDIR}/ollama-portable.tgz" || err "Download failed"

log "Extracting to ${DESTDIR}…"
run_cmd sudo mkdir -p "$DESTDIR"
run_cmd sudo tar -C "$DESTDIR" -xzf "${TMPDIR}/ollama-portable.tgz" || err "Extraction failed"

log "Starting Ollama service…"
run_cmd sudo chmod +x "${DESTDIR}/start-ollama.sh"

# background under run_cmd so redirection + & actually apply
LOG_IPEX=/var/log/ollama-ipex.log
run_cmd "sudo nohup \"${DESTDIR}/start-ollama.sh\" > \"${LOG_IPEX}\" 2>&1 &"

log "Ollama launched; logs → ${LOG_IPEX}"

# cleanup tempdir
run_cmd rm -rf "$TMPDIR"
