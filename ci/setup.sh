#!/bin/bash
# ── Embedded setup script for webstack-installer.run ────────────────────────
# This runs INSIDE the makeself temporary extraction directory.

set -e

SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ══════════════════════════════════════════════════════════════════════════════
#  ABSOLUTE REFUSAL TO RUN AS ROOT
# ══════════════════════════════════════════════════════════════════════════════
if [ "$EUID" -eq 0 ]; then
    echo ""
    echo "═══════════════════════════════════════════════════"
    echo "  DO NOT run this installer with sudo!"
    echo "═══════════════════════════════════════════════════"
    echo ""
    echo "  Correct:  bash webstack-installer.run"
    echo "  Wrong:    sudo bash webstack-installer.run"
    echo ""
    echo "  The installer calls sudo internally ONLY to"
    echo "  copy files to /opt/webstack and install Qt deps."
    echo ""
    if [ -n "$SUDO_USER" ]; then
        echo "  Auto-relaunching as $SUDO_USER..."
        exec su - "$SUDO_USER" -c "bash '$(readlink -f "$0")'"
    fi
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
#  COLOUR HELPERS (subtle, for the setup wrapper only)
# ══════════════════════════════════════════════════════════════════════════════
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_ok()   { echo -e "${GREEN}  [OK]${NC} $1"; }
log_info() { echo -e "${GREEN} [INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW} [WARN]${NC} $1"; }

# ══════════════════════════════════════════════════════════════════════════════
#  DISTRO DETECTION
# ══════════════════════════════════════════════════════════════════════════════
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release; echo "${ID}"
    elif command -v lsb_release &>/dev/null; then
        lsb_release -is | tr '[:upper:]' '[:lower:]'
    else
        echo "unknown"
    fi
}
DISTRO_ID=$(detect_distro)

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL Qt RUNTIME DEPENDENCIES
# ══════════════════════════════════════════════════════════════════════════════
#
# The Nuitka-compiled PySide6 manager bundles its own Qt .so files, but
# Qt still links against system libraries (libxcb, libEGL, libxkbcommon,
# etc.).  Most desktop Linux systems already have these, but a minimal
# server install may not.  We install them proactively — they're small
# and harmless if already present.
#
install_qt_runtime_deps() {
    local manager_bin="$SELFDIR/webstack/manager/webstack-manager"
    [ ! -f "$manager_bin" ] && return 0   # No manager bundled — skip

    log_info "Checking Qt runtime dependencies for the GUI manager..."

    # Quick check: try to ldd the binary; if no "not found", we're good
    local missing
    missing=$(ldd "$manager_bin" 2>/dev/null | grep "not found" || true)
    if [ -z "$missing" ]; then
        log_ok "All shared libraries resolved — no extra packages needed"
        return 0
    fi

    log_warn "Missing libraries detected — installing Qt runtime deps..."

    local pkg_list=() install_cmd=""

    case "$DISTRO_ID" in
        ubuntu|debian|linuxmint|pop)
            pkg_list=(
                libegl1 libxcb1 libxcb-cursor0 libxcb-icccm4
                libxcb-image0 libxcb-keysyms1 libxcb-randr0
                libxcb-render-util0 libxcb-shape0 libxcb-xfixes0
                libxcb-xinerama0 libxcb-xkb1
                libxkbcommon-x11-0 libxkbcommon0
                libgl1 libfontconfig1 libfreetype6 libdbus-1-3
            )
            install_cmd="sudo apt-get update && sudo apt-get install -y"
            ;;
        fedora|rhel|centos|rocky|alma)
            pkg_list=(
                mesa-libEGL libxcb libxcb-cursor
                libxkbcommon libxkbcommon-x11
                mesa-libGL fontconfig freetype dbus-libs
            )
            install_cmd="sudo dnf install -y"
            ;;
        arch|manjaro|cachyos|endeavouros)
            pkg_list=(
                libegl libxcb libxcb-cursor
                libxkbcommon libxkbcommon-x11
                mesa fontconfig freetype2 dbus
            )
            install_cmd="sudo pacman -S --noconfirm"
            ;;
        opensuse*|sles)
            pkg_list=(
                libEGL1 libxcb1 libxcb-cursor
                libxkbcommon0 libxkbcommon-x11-0
                Mesa-libGL1 fontconfig freetype2 libdbus-1-3
            )
            install_cmd="sudo zypper install -y"
            ;;
        alpine)
            pkg_list=(
                mesa-gl egl-libs libxcb libxcb-cursor
                libxkbcommon libxkbcommon-x11
                mesa fontconfig freetype dbus-libs
            )
            install_cmd="sudo apk add"
            ;;
        *)
            log_warn "Unknown distro '$DISTRO_ID' — cannot auto-install Qt deps"
            log_warn "Install them manually. Missing:"
            echo "$missing"
            return 0
            ;;
    esac

    if command -v sudo &>/dev/null; then
        eval "$install_cmd ${pkg_list[*]}" && {
            log_ok "Qt runtime dependencies installed"
        } || {
            log_warn "Some packages failed — the manager may still work on desktop systems"
        }
    else
        log_warn "sudo not available — cannot install Qt deps automatically"
        log_warn "The GUI manager may not work. CLI tools are unaffected."
    fi

    # Final verification
    missing=$(ldd "$manager_bin" 2>/dev/null | grep "not found" || true)
    if [ -n "$missing" ]; then
        echo ""
        log_warn "Still missing (manager may not launch):"
        echo "$missing"
        echo ""
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  SETUP CONTROL PANEL
# ══════════════════════════════════════════════════════════════════════════════
setup_control_panel() {
    local manager_bin="/opt/webstack/manager/webstack-manager"
    [ ! -f "$manager_bin" ] && return 0   # No manager bundled — skip

    log_info "Setting up WebStack Manager..."

    mkdir -p "$HOME/.local/bin"

    # ── Wrapper script (handles env vars + headless detection) ─────────
    cat > "$HOME/.local/bin/webstack-manager" << 'WRAPPER_EOF'
#!/bin/bash
export WEBSTACK_HOME="/opt/webstack"

# Headless / SSH detection
if [ -z "$DISPLAY" ] && [ -z "$WAYLAND_DISPLAY" ]; then
    echo ""
    echo "  WebStack Manager is a GUI application."
    echo ""
    echo "  No display server detected. Options:"
    echo ""
    echo "    1. If SSH'd in, reconnect with:  ssh -X user@host"
    echo "    2. Use CLI tools instead:"
    echo "       webstack-start   webstack-stop   webstack-php 8.4"
    echo "       webstack-mysql   webstack-psql    webstack-php-cli"
    echo ""
    exit 1
fi

exec "$WEBSTACK_HOME/manager/webstack-manager" "$@"
WRAPPER_EOF
    chmod +x "$HOME/.local/bin/webstack-manager"
    log_ok "Created ~/.local/bin/webstack-manager"

    # ── Uninstaller symlink ────────────────────────────────────────────
    ln -sf /opt/webstack/uninstall.sh "$HOME/.local/bin/webstack-uninstall"
    chmod +x /opt/webstack/uninstall.sh 2>/dev/null || true
    log_ok "Created ~/.local/bin/webstack-uninstall"

    # ── Desktop entry (application menu integration) ───────────────────
    local desktop_dir="$HOME/.local/share/applications"
    mkdir -p "$desktop_dir"

    cat > "$desktop_dir/webstack-manager.desktop" << DESKTOP_EOF
[Desktop Entry]
Name=WebStack Manager
Comment=Manage your portable web development stack
Exec=$HOME/.local/bin/webstack-manager
Icon=applications-internet
Terminal=false
Type=Application
Categories=Development;WebDevelopment;IDE;
StartupNotify=true
StartupWMClass=webstack-manager
DESKTOP_EOF
    chmod 644 "$desktop_dir/webstack-manager.desktop"
    log_ok "Created desktop entry (appears in application menu)"

    # ── Update desktop database (silent if not available) ──────────────
    if command -v update-desktop-database &>/dev/null; then
        update-desktop-database "$desktop_dir" 2>/dev/null || true
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  BANNER
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║     Linux Universal Web Stack Installer                  ║"
echo "║     (Pre-compiled Release)                               ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  This will install a pre-compiled web stack to:          ║"
echo "║    /opt/webstack   (binaries — shared, ~600MB)           ║"
echo "║    ~/.webstack/    (your data — per-user)                ║"
echo "║    ~/webstack-www/ (your code — per-user)                ║"
echo "║                                                          ║"
echo "║  Includes: Nginx, PHP 8.5/8.4/8.3, MariaDB, PostgreSQL   ║"
echo "║             + WebStack Manager (GUI control panel)       ║"
echo "║                                                          ║"
echo "║  Requires: sudo access, x86_64, glibc ≥ 2.35             ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

read -p "Continue? (y/n) " -n 1 -r
echo ""
[[ ! $REPLY =~ ^[Yy]$ ]] && { echo "Aborted."; exit 0; }

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL COMPILED STACK TO /opt/webstack
# ══════════════════════════════════════════════════════════════════════════════
if [ -d /opt/webstack ] && [ -f /opt/webstack/.compiled ]; then
    echo "[INFO] /opt/webstack already exists and is compiled."
    echo "       Skipping system installation."
else
    echo "[INFO] Installing compiled stack to /opt/webstack ..."
    echo "       (this requires sudo — copying ~600MB of binaries)"

    sudo mkdir -p /opt

    if [ -d /opt/webstack ]; then
        echo "[INFO] Removing existing /opt/webstack ..."
        sudo rm -rf /opt/webstack
    fi

    sudo cp -a "$SELFDIR/webstack" /opt/webstack
    sudo chown -R "$USER:$(id -gn)" /opt/webstack

    # Restore directories pruned by CI's "remove empty dirs" step
    mkdir -p /opt/webstack/nginx/logs

    echo "[INFO] Compiled stack installed successfully."
fi

echo ""

# ══════════════════════════════════════════════════════════════════════════════
#  INSTALL Qt RUNTIME DEPS (for the GUI manager)
# ══════════════════════════════════════════════════════════════════════════════
install_qt_runtime_deps

# ══════════════════════════════════════════════════════════════════════════════
#  SETUP CONTROL PANEL (symlink + desktop entry)
# ══════════════════════════════════════════════════════════════════════════════
setup_control_panel

echo ""

# ══════════════════════════════════════════════════════════════════════════════
#  RUN PHASE 2 (USER SETUP)
# ══════════════════════════════════════════════════════════════════════════════
# ── Copy documentation to web root ──────────────────────────────────
if [ -d "$SELFDIR/docs" ]; then
    mkdir -p "$HOME/webstack-www"
    cp -a "$SELFDIR/docs" "$HOME/webstack-www/docs"
fi

echo "[INFO] Starting user environment setup..."
echo ""

exec bash "$SELFDIR/installer.sh" --phase2-only
