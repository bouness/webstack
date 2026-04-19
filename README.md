# 🚀 Linux Universal Isolated Web Stack

A fully portable, zero-system-dependency web development stack for Linux. Compiles Nginx, multiple PHP versions, MariaDB, and PostgreSQL into an isolated environment at `/opt/webstack`, with per-user data separation.

Includes a **GUI Manager** for easily starting/stopping services, switching PHP versions, and viewing logs.

![GitHub Actions Build](https://img.shields.io/github/actions/workflow/status/bouness/webstack/build-release.yml?style=flat-square)
![Version](https://img.shields.io/badge/dynamic/json?url=https://api.github.com/repos/bouness/webstack/releases/latest&query=tag_name&label=Release&color=blue)
![WebStack Manager](https://img.shields.io/badge/WebStack-Manager-blue)
![PySide6](https://img.shields.io/badge/GUI-PySide6-green)
![Portable](https://img.shields.io/badge/Architecture-Portable-orange)

## 💖 Support Project
**Bitcoin:** `34Db9CqBjwiFt3SmaPUQPW4Z3QMjMrfVFh`

**Venmo:** Scan to donate via Venmo to support the project:

![Venmo QR](https://api.qrserver.com/v1/create-qr-code/?size=150x150&data=https://venmo.com/youness-bougteb)

## ✨ Features

- **Fully Isolated**: No system package conflicts. Everything lives in `/opt/webstack`.
- **Per-User Data**: Configs, databases, and logs are stored in `~/.webstack/`.
- **Multiple PHP Versions**: Seamlessly switch between PHP 8.5, 8.4, and 8.3 via CLI or GUI.
- **All Dependencies Bundled**: Custom-compiled OpenSSL, cURL, ICU, libsodium, etc.
- **GUI Control Panel**: Start/stop services, switch PHP, view logs, and test connections.
- **Single .run Installer**: Download one file, run it, and you're done. No internet required during installation.

## 📦 What's Inside

| Component | Version | Notes |
|-----------|---------|-------|
| Nginx | 1.28.3 | HTTP/2, SSL, FastCGI |
| PHP | 8.5.5 / 8.4.20 / 8.3.30 | FPM, OPCache JIT, GD, Intl, Sodium, XSL, Zip, PDO |
| MariaDB | 11.8.6 | Drop-in MySQL replacement |
| PostgreSQL | 17.9 | Advanced SQL database |
| OpenSSL | 3.6.2 | Self-compiled, not system version |

## 🛠️ Quick Install

1. Download the latest `.run` file from the [Releases](../../releases) page.
2. Make it executable and run it (do **NOT** use `sudo`):

```bash
chmod +x webstack-installer-*.run
./webstack-installer-*.run
```

3. Add CLI tools to your PATH:
```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
```

4. Start the stack:
```bash
webstack-start
```

5. Open [http://localhost:8080](http://localhost:8080) in your browser.

## 🖥️ Usage

### CLI Tools
```bash
webstack-start        # Start all services
webstack-stop         # Stop all services
webstack-php 8.4      # Switch active PHP version
webstack-php-cli -v   # Run PHP CLI commands
webstack-mysql        # Open MariaDB shell
webstack-psql         # Open PostgreSQL shell
webstack-manager      # Open GUI control panel
```

### GUI Manager
Search for **"WebStack Manager"** in your desktop application menu, or run `webstack-manager` in a terminal. 
*(Note: Requires a display server. For SSH, use `ssh -X`)*.

### Default Credentials
| Service | User | Password |
|---------|------|----------|
| MariaDB | root | `123456` |
| MariaDB | webstack | `webstack` |
| PostgreSQL | postgres | `123456` |

## 🏗️ Architecture

WebStack is split into two distinct locations:

- **`/opt/webstack`** (System-wide, shared): Contains compiled binaries and libraries. This is the only part packaged in the `.run` release file.
- **`~/.webstack/`** (Per-user): Contains runtime data, sockets, PID files, and configs (e.g., `nginx.conf`, `my.cnf`).
- **`~/webstack-www/`** (Per-user): The Nginx document root for your projects.

## 🧹 Uninstalling

Run the bundled uninstaller:
```bash
webstack-uninstall
```
This safely stops services, removes `/opt/webstack` and `~/.webstack`, and asks for confirmation before deleting `~/webstack-www` (your project files).

## 🔧 Build

**Build Environment:** Ubuntu 22.04 (for maximum glibc compatibility across Linux distros).
**Build Time:** ~2-3 hours (mostly ICU and MariaDB compilation).

## 📁 Repository Structure

```
├── .github/workflows/build-release.yml
├── ci/
│   ├── setup.sh          # Embedded in .run: copies to /opt, runs Phase 2
│   └── uninstall.sh      # Embedded in .run: safe removal
├── docs/
│   └── index.html        # WebStack Documentation
├── cp.py                 # Python GUI Manager source
├── install.sh            # Main installer script (Phase 1 & 2)
├── LICENSE
└── README.md
```
