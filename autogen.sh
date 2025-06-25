@@ -110,85 +110,84 @@ id "$TARGET_USER" | grep -qw docker || usermod -aG docker "$TARGET_USER"
-###############################################################################
-# — Docker (for optional Ollama) ###############################################
-###############################################################################
-if ! command -v docker &>/dev/null; then
-  log "Installing Docker Engine"
-  getent group docker >/dev/null || groupadd docker
-  ensure_pkg ca-certificates; ensure_pkg curl; ensure_pkg gnupg
-  install -d -m 0755 /etc/apt/keyrings
-  curl -fsSL https://download.docker.com/linux/debian/gpg \
-    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
-  chmod a+r /etc/apt/keyrings/docker.gpg
-  echo "deb [arch=$(dpkg --print-architecture) \
-    signed-by=/etc/apt/keyrings/docker.gpg] \
-    https://download.docker.com/linux/debian \
-    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
-    > /etc/apt/sources.list.d/docker.list
-  apt-get -qq update
-  apt-get -qq install -y docker-ce docker-ce-cli containerd.io \
-                         docker-buildx-plugin docker-compose-plugin
-  systemctl enable --now docker
-fi
-
-id "$TARGET_USER" | grep -qw docker || usermod -aG docker "$TARGET_USER"
-
-while true; do
-  read -r -p "Enter Ollama API URL [${OLLAMA_API_URL:-http://localhost:11434}]: " in </dev/tty || true
-  OLLAMA_API_URL="${in:-$OLLAMA_API_URL}"
-  OLLAMA_API_URL="${OLLAMA_API_URL%/}"
-  log "Probing Ollama @ $OLLAMA_API_URL"
-
-  if curl -fsSL --max-time 5 "$OLLAMA_API_URL/api/tags" -o /tmp/ollama.json; then
-    jq -e '.models|length>0' /tmp/ollama.json &>/dev/null && {
-      sed -i "s#^OLLAMA_API_URL=.*#OLLAMA_API_URL=$OLLAMA_API_URL#" "$ENV_FILE"
-      break
-    } || log_warn "API OK but zero models"
-  else
-    log_warn "Cannot reach API"
-    if [[ "$OLLAMA_API_URL" == "http://localhost:11434" ]]; then
-      read -r -p "Install local Ollama via Docker? [y/N]: " yn </dev/tty
-      [[ ${yn,,} == y ]] && \
-        docker run -d --name ollama -v ollama_data:/root/.ollama \
-        -p 11434:11434 ghcr.io/jmorganca/ollama:latest && sleep 6 && continue
-    fi
-  fi
-  echo "Try another URL or Ctrl-C to abort."
-done
+###############################################################################
+# — Intel-accelerated Ollama (portable zip, no Docker) ########################
+###############################################################################
+
+install_ollama_intel() {
+  # skip if ollama already on PATH
+  command -v ollama &>/dev/null && { log "ollama found; skipping install"; return; }
+
+  TAG="${OLLAMA_VERSION:-v0.6.2}"
+  ZIP_FILE="ollama-portable-${TAG}-linux.zip"
+  DOWNLOAD_URL="https://github.com/ollama/ollama/releases/download/${TAG}/${ZIP_FILE}"
+
+  log "Downloading Ollama ${TAG}"
+  curl -fsSL "$DOWNLOAD_URL" -o /tmp/ollama.zip
+  mkdir -p /usr/local/bin/ollama-bin
+  unzip -q /tmp/ollama.zip -d /usr/local/bin/ollama-bin
+  ln -sf /usr/local/bin/ollama-bin/ollama /usr/local/bin/ollama
+  rm /tmp/ollama.zip
+  chmod +x /usr/local/bin/ollama
+}
+
+# install the native binary
+install_ollama_intel
+
+# set up Intel GPU vars
+export OLLAMA_NUM_GPU=999
+export ONEAPI_DEVICE_SELECTOR=level_zero:0
+export SYCL_CACHE_PERSISTENT=1
+export no_proxy=localhost,127.0.0.1
+
+# probe & serve loop
+OLLAMA_API_URL=${OLLAMA_API_URL:-http://localhost:11434}
+while true; do
+  log "Probing Ollama @ $OLLAMA_API_URL"
+  if curl -fsSL --max-time 5 "$OLLAMA_API_URL/api/tags" -o /tmp/ollama.json \
+     && jq -e '.models|length>0' /tmp/ollama.json &>/dev/null; then
+    # persist the URL back into .env
+    sed -i "s|^OLLAMA_API_URL=.*|OLLAMA_API_URL=$OLLAMA_API_URL|" "$ENV_FILE"
+    break
+  fi
+
+  log_warn "Ollama API unreachable; launching 'ollama serve'"
+  nohup ollama serve --host 0.0.0.0 >>"$APP_LOG" 2>&1 &
+  sleep 6
+done
