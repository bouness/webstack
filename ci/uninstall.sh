#!/bin/bash
# ── WebStack Uninstaller ──────────────────────────────────────────────────────
# Removes /opt/webstack (binaries), ~/.webstack (user data/config/databases),
# all CLI symlinks, the desktop entry, and optionally ~/webstack-www (your code).

set -e

# ══════════════════════════════════════════════════════════════════════════════
#  REFUSE TO RUN AS ROOT
# ══════════════════════════════════════════════════════════════════════════════
if [ "$EUID" -eq 0 ]; then
    echo ""
    echo "  DO NOT run this script with sudo or as root."
    echo "  It calls sudo internally only to remove /opt/webstack."
    echo ""
    echo "  Correct:  bash uninstall.sh"
    echo ""
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
#  COLOURS
# ══════════════════════════════════════════════════════════════════════════════
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
log_ok()   { echo -e "${GREEN}  [OK]${NC} $1"; }
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_err()  { echo -e "${RED}[ERR]${NC} $1"; }

# ══════════════════════════════════════════════════════════════════════════════
#  PATHS  (must match install.sh)
# ══════════════════════════════════════════════════════════════════════════════
INSTALL_DIR="/opt/webstack"
USER_DIR="$HOME/.webstack"
USER_WWW="$HOME/webstack-www"

# ══════════════════════════════════════════════════════════════════════════════
#  BANNER
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║          WebStack Uninstaller                            ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  This will remove:                                       ║"
echo "║    /opt/webstack        compiled binaries (~600 MB)      ║"
echo "║    ~/.webstack/         configs, databases, logs         ║"
echo "║    ~/.local/bin/webstack-*   CLI symlinks                ║"
echo "║    ~/.local/bin/webstack-manager   GUI wrapper           ║"
echo "║    ~/.local/share/applications/webstack-manager.desktop  ║"
echo "║                                                          ║"
echo "║  You will be asked separately about:                     ║"
echo "║    ~/webstack-www/      your web files / projects        ║"
echo "║                                                          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ══════════════════════════════════════════════════════════════════════════════
#  CONFIRM — MAIN UNINSTALL
# ══════════════════════════════════════════════════════════════════════════════
read -r -p "  Continue with uninstall? [y/N] " REPLY
echo ""
if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
    echo "  Aborted — nothing was changed."
    echo ""
    exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
#  STOP RUNNING SERVICES FIRST
# ══════════════════════════════════════════════════════════════════════════════
stop_services() {
    log_info "Stopping any running WebStack services..."

    local stopped_any=0

    # ── Nginx ──────────────────────────────────────────────────────────────
    local nginx_pid_file="$USER_DIR/nginx/nginx.pid"
    if [ -f "$nginx_pid_file" ]; then
        local nginx_pid; nginx_pid=$(cat "$nginx_pid_file" 2>/dev/null || true)
        if [ -n "$nginx_pid" ] && kill -0 "$nginx_pid" 2>/dev/null; then
            "$INSTALL_DIR/nginx/nginx" -s quit -c "$USER_DIR/nginx/nginx.conf" 2>/dev/null && \
                log_ok "Nginx stopped" || \
                kill "$nginx_pid" 2>/dev/null && log_ok "Nginx killed"
            stopped_any=1
        fi
    fi

    # ── PHP-FPM (all versions) ─────────────────────────────────────────────
    for pid_file in "$USER_DIR"/php/*/php-fpm.pid; do
        [ -f "$pid_file" ] || continue
        local pid; pid=$(cat "$pid_file" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null && log_ok "PHP-FPM ($pid_file) stopped"
            stopped_any=1
        fi
    done

    # ── MariaDB ────────────────────────────────────────────────────────────
    local mariadb_pid_file="$USER_DIR/mariadb/mariadb.pid"
    if [ -f "$mariadb_pid_file" ]; then
        local mariadb_pid; mariadb_pid=$(cat "$mariadb_pid_file" 2>/dev/null || true)
        if [ -n "$mariadb_pid" ] && kill -0 "$mariadb_pid" 2>/dev/null; then
            "$INSTALL_DIR/mariadb/bin/mariadb-admin" \
                --socket="$USER_DIR/mariadb/mariadb.sock" \
                --user=root --password=123456 \
                shutdown 2>/dev/null && log_ok "MariaDB stopped" || {
                kill "$mariadb_pid" 2>/dev/null
                sleep 2
                log_ok "MariaDB killed"
            }
            stopped_any=1
        fi
    fi

    # ── PostgreSQL ─────────────────────────────────────────────────────────
    local pg_pid_file="$USER_DIR/postgresql/data/postmaster.pid"
    if [ -f "$pg_pid_file" ]; then
        "$INSTALL_DIR/postgresql/bin/pg_ctl" \
            -D "$USER_DIR/postgresql/data" \
            stop -m fast 2>/dev/null && log_ok "PostgreSQL stopped"
        stopped_any=1
    fi

    [ "$stopped_any" -eq 0 ] && log_info "No running services found."
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  REMOVE CLI SYMLINKS
# ══════════════════════════════════════════════════════════════════════════════
remove_symlinks() {
    log_info "Removing CLI symlinks from ~/.local/bin/ ..."
    local links=(
        webstack-start
        webstack-stop
        webstack-php
        webstack-mysql
        webstack-psql
        webstack-php-cli
        webstack-composer
        webstack-manager
    )
    for link in "${links[@]}"; do
        local path="$HOME/.local/bin/$link"
        if [ -L "$path" ] || [ -f "$path" ]; then
            rm -f "$path" && log_ok "Removed $path"
        fi
    done
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  REMOVE DESKTOP ENTRY
# ══════════════════════════════════════════════════════════════════════════════
remove_desktop_entry() {
    local desktop_file="$HOME/.local/share/applications/webstack-manager.desktop"
    if [ -f "$desktop_file" ]; then
        rm -f "$desktop_file" && log_ok "Removed desktop entry"
        if command -v update-desktop-database &>/dev/null; then
            update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
        fi
    fi
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  REMOVE USER DATA  (~/.webstack)
# ══════════════════════════════════════════════════════════════════════════════
remove_user_data() {
    if [ -d "$USER_DIR" ]; then
        log_warn "Removing $USER_DIR  (configs, databases, logs) ..."
        rm -rf "$USER_DIR" && log_ok "Removed $USER_DIR"
    else
        log_info "$USER_DIR not found — skipping."
    fi
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  REMOVE COMPILED BINARIES  (/opt/webstack)
# ══════════════════════════════════════════════════════════════════════════════
remove_opt() {
    if [ -d "$INSTALL_DIR" ]; then
        log_info "Removing $INSTALL_DIR  (requires sudo) ..."
        sudo rm -rf "$INSTALL_DIR" && log_ok "Removed $INSTALL_DIR"
    else
        log_info "$INSTALL_DIR not found — skipping."
    fi
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  OPTIONAL: REMOVE ~/webstack-www
# ══════════════════════════════════════════════════════════════════════════════
ask_remove_www() {
    if [ ! -d "$USER_WWW" ]; then
        log_info "$USER_WWW not found — nothing to remove."
        echo ""
        return
    fi

    # Count files so the user knows what's at stake
    local file_count; file_count=$(find "$USER_WWW" -maxdepth 3 -type f 2>/dev/null | wc -l)

    echo "──────────────────────────────────────────────────────────"
    echo ""
    echo "  Your web files are at:  $USER_WWW"
    echo "  Files found:            $file_count"
    echo ""
    echo "  These are YOUR project files — apps, websites, etc."
    echo "  They are NOT removed by default."
    echo ""
    read -r -p "  Delete ~/webstack-www as well? [y/N] " WWW_REPLY
    echo ""

    if [[ "$WWW_REPLY" =~ ^[Yy]$ ]]; then
        # Extra confirmation because this is destructive and irreversible
        echo "  ⚠  This permanently deletes all files in $USER_WWW"
        read -r -p "  Type YES to confirm: " WWW_CONFIRM
        echo ""
        if [ "$WWW_CONFIRM" = "YES" ]; then
            rm -rf "$USER_WWW" && log_ok "Removed $USER_WWW"
        else
            log_info "Skipped — $USER_WWW kept."
        fi
    else
        log_info "Kept $USER_WWW — your project files are safe."
    fi
    echo ""
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════
stop_services
remove_symlinks
remove_desktop_entry
remove_user_data
remove_opt
ask_remove_www

echo "══════════════════════════════════════════════════════════"
log_ok "WebStack has been uninstalled."
echo ""

if [ -d "$USER_WWW" ]; then
    echo "  Your web files are still at:  $USER_WWW"
    echo "  Remove manually if you want:  rm -rf $USER_WWW"
    echo ""
fi

echo "  To reinstall later:"
echo "    bash webstack-installer-*.run"
echo "  (or from source: bash install.sh)"
echo ""
echo "══════════════════════════════════════════════════════════"
