#!/usr/bin/env bash
set -Eeuo pipefail

########################################
# 1. Host prep for compose-intel-gpu-and-build
########################################

REPO_URL="https://github.com/pi0n00r/self-hosted-ai-starter-kit.git"
BRANCH="compose-intel-gpu-and-build"

log() { echo "[HOST_SETUP][INFO] $*"; }
err() { echo "[HOST_SETUP][ERROR] $*" >&2; exit 1; }

log "Cloning self-hosted-ai-starter-kit ($BRANCH)…"
rm -rf self-hosted-ai-starter-kit
git clone --depth 1 --branch "$BRANCH" "$REPO_URL" \
  || err "git clone failed"
cd self-hosted-ai-starter-kit/host-prep

log "Running host-prep.sh (GPU profile)…"
sudo bash host-prep.sh -y --profile gpu-nvidia \
  || err "host-prep failed"
cd ../..

########################################
# 2. Download & launch Ollama portable ZIP via Intel IPEX-LLM
########################################

# version/tag of the IPEX-LLM release you want
IPEX_RELEASE="v0.6.2"
TMPDIR="$(mktemp -d)"
DESTDIR="/opt/ollama-ipex"

log "Downloading Ollama portable zip from intel/ipex-llm:$IPEX_RELEASE…"
curl -fsSL \
  "https://github.com/intel/ipex-llm/releases/download/${IPEX_RELEASE}/ollama_portable_linux_${IPEX_RELEASE}.tgz" \
  -o "${TMPDIR}/ollama-portable.tgz" \
  || err "download failed"

sudo mkdir -p "$DESTDIR"
sudo tar -C "$DESTDIR" -xzf "${TMPDIR}/ollama-portable.tgz" \
  || err "tar failed"

log "Starting Ollama service…"
# make sure start script is executable
sudo chmod +x "${DESTDIR}/start-ollama.sh"
sudo nohup "${DESTDIR}/start-ollama.sh" \
  > /var/log/ollama-ipex.log 2>&1 &

log "Ollama launched; listening on port 11434."
