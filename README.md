# AutoGenesis

🚀 **Experimental Installer for Microsoft AutoGen**

[![Latest Release](https://img.shields.io/github/v/release/pi0n00r/AutoGenesis?include_prereleases&label=AutoGenesis%20Release)](https://github.com/pi0n00r/AutoGenesis/releases/tag/v0.1.1-experimental)

> Modular and extensible, with PostgreSQL and Ollama fallback baked in.

---

## 📦 Overview

**AutoGenesis** is an idempotent installation toolkit tailored to deploy Microsoft's [AutoGen](https://microsoft.github.io/autogen/) with:

- 🐍 Python + PostgreSQL support
- 💡 Optional fallback: local LLM via Ollama
- 🔧 Configurable `.env` for dynamic setups
- 🖥️ Works with Proxmox LXC templates

---

## 🚀 Quick Start

### 1. Clone & enter the repo
```bash
git clone https://github.com/pi0n00r/AutoGenesis.git
cd AutoGenesis
2. Configure .env as needed
Tweak paths, ports, or LLM backend by editing the included .env file.

3. Run the installer
bash
bash install.sh
🔬 Experimental Status
This is an active, exploratory project. Use with curiosity—PRs and feedback welcome.

📄 License & Credits
Forked from fitoori/AutoGenesis Shell scripting, LXC integration, and modular design by @pi0n00r Licensed under the MIT License
