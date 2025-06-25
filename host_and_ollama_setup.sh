#!/usr/bin/env bash
set -Eeuo pipefail
shopt -s inherit_errexit lastpipe

#–– Logging must match autogen.sh’s LOG_FILE ––#
# Use a double-quoted trap string so the inner date +'%F %T' stays intact:
trap "
  rc=\$?;
  echo \"\$(date +'%F %T') [HOST_SETUP][ERROR] line \$LINENO: \\\"\$BASH_COMMAND\\\" (exit \$rc)\" \
    | tee -a \"\$LOG_FILE\" >&2
" ERR

#–– Find this script’s dir even when symlinked ––#
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

#–– Allow dry-run mode from outer script ––#
DRY_RUN="${DRY_RUN:-false}"
run_cmd() {
  if [[ "$DRY_RUN" == true ]]; then
    echo "DRY-RUN: $*"
  else
    eval "$@"
  fi
}

log() { echo "$(date +'%F %T') [HOST_SETUP][INFO] $*" | tee -a "$LOG_FILE"; }
err() { echo "$(date +'%F %T') [HOST_SETUP][ERROR] $*" | tee -a "$LOG_FILE" >&2; exit 1; }

########################################
# 1. Host prep for compose-intel-gpu-and-build
########################################
REPO_URL="https://github.com/pi0n00r/self-hosted-ai-starter-kit.git"
BRANCH="compose-intel-gpu-and-build"

log "Cloning self-hosted-ai-starter-kit (branch: $BRANCH)…"
run_cmd rm -rf self-hosted-ai-starter-kit
run_cmd git clone --depth 1 --branch "$BRANCH" "$REPO_URL" \
  || err "git clone failed"

cd self-hosted-ai-starter-kit/host-prep \
  || err "cannot enter host-prep directory"

log "Running host-prep.sh (GPU profile)…"
run_cmd sudo bash host-prep.sh -y --profile gpu-nvidia \
  || err "host-prep.sh failed"

cd "$SCRIPT_DIR"   # back to this script’s dir

########################################
# 2. Download & launch Ollama portable ZIP via Intel IPEX-LLM
########################################
IPEX_RELEASE="v0.6.2"
TMPDIR="$(mktemp -d)"
DESTDIR="/opt/ollama-ipex"

log "Downloading Ollama portable archive (release $IPEX_RELEASE)…"
run_cmd curl -fsSL \
  "https://github.com/intel/ipex-llm/releases/download/${IPEX_RELEASE}/ollama_portable_linux_${IPEX_RELEASE}.tgz" \
  -o "${TMPDIR}/ollama-portable.tgz" \
  || err "download failed"

run_cmd sudo mkdir -p "$DESTDIR"
run_cmd sudo tar -C "$DESTDIR" -xzf "${TMPDIR}/ollama-portable.tgz" \
  || err "tar extraction failed"

log "Starting Ollama service…"
run_cmd sudo chmod +x "${DESTDIR}/start-ollama.sh"
# run in background, logging its output (must be passed as one string)
# capture your IPEX log path
LOG_IPEX=/var/log/ollama-ipex.log
# pass the entire background invocation as a single string
run_cmd "sudo nohup \"${DESTDIR}/start-ollama.sh\" \
  > \"${LOG_IPEX}\" 2>&1 &"

# note: if DRY_RUN=false this actually backgrounds; if true you’ll see the whole
# string echoed but nothing runs.

log "Ollama launched; listening on port 11434."

# cleanup temp
run_cmd rm -rf "$TMPDIR"
