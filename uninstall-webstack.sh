#!/bin/bash
# WebStack Uninstaller
# Stops all services, removes all files, and cleans up shell integrations.

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

STACK_DIR="${WEBSTACK_HOME:-$HOME/webstack}"

# ── Sanity checks ────────────────────────────────────────────────────────────
if [ "$EUID" -eq 0 ]; then
    log_error "Do not run as root."
    exit 1
fi

if [ ! -d "$STACK_DIR" ]; then
    log_error "Stack directory not found: $STACK_DIR"
    log_warn  "Nothing to uninstall."
    exit 0
fi

echo ""
echo "========================================"
echo "  WebStack Uninstaller"
echo "========================================"
echo ""
echo "This will permanently remove:"
echo "  • All services (Nginx, PHP-FPM, MariaDB, PostgreSQL)"
echo "  • The entire stack directory: $STACK_DIR"
echo "  • Symlinks in ~/.local/bin"
echo "  • Desktop entry (if present)"
echo ""
echo "Your web files in $STACK_DIR/www will also be deleted."
echo ""
read -p "Are you sure you want to uninstall WebStack? (yes/no) " -r CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    log_info "Uninstall cancelled."
    exit 0
fi

# ── Stop all services ────────────────────────────────────────────────────────
log_info "Stopping all services..."

stop_nginx() {
    local pid_file="$STACK_DIR/nginx/nginx.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            log_info "Nginx stopped"
        fi
    fi

    # Belt-and-suspenders: ask nginx binary to quit if pid file is stale
    local nginx_bin="$STACK_DIR/nginx/nginx"
    if [ -f "$nginx_bin" ]; then
        "$nginx_bin" -s quit 2>/dev/null || true
    fi
}

stop_php() {
    local pid_file="$STACK_DIR/php/current/php-fpm.pid"
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
            sleep 1
            log_info "PHP-FPM stopped"
        fi
    fi
}

stop_mariadb() {
    local mysql_admin="$STACK_DIR/mariadb/bin/mariadb-admin"
    local socket="$STACK_DIR/mariadb/mariadb.sock"
    local pid_file="$STACK_DIR/mariadb/mariadb.pid"

    if [ -f "$mysql_admin" ] && [ -S "$socket" ]; then
        "$mysql_admin" --socket="$socket" shutdown 2>/dev/null || true
        sleep 2
        log_info "MariaDB stopped"
    elif [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file")
        kill "$pid" 2>/dev/null || true
        sleep 1
        log_info "MariaDB stopped (via PID)"
    fi
}

stop_postgresql() {
    local pg_ctl="$STACK_DIR/postgresql/bin/pg_ctl"
    local pgdata="$STACK_DIR/postgresql/data"
    local pid_file="$pgdata/postmaster.pid"

    if [ -f "$pg_ctl" ] && [ -f "$pid_file" ]; then
        "$pg_ctl" -D "$pgdata" stop -m fast 2>/dev/null || true
        sleep 2
        log_info "PostgreSQL stopped"
    fi
}

stop_nginx
stop_php
stop_mariadb
stop_postgresql

# Brief wait for sockets / pid files to clear
sleep 1

# ── Verify nothing is still running ─────────────────────────────────────────
log_info "Verifying services are stopped..."

still_running=()

check_pid_alive() {
    local label=$1
    local pid_file=$2
    if [ -f "$pid_file" ]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            still_running+=("$label (PID $pid)")
        fi
    fi
}

check_pid_alive "Nginx"      "$STACK_DIR/nginx/nginx.pid"
check_pid_alive "PHP-FPM"    "$STACK_DIR/php/current/php-fpm.pid"
check_pid_alive "MariaDB"    "$STACK_DIR/mariadb/mariadb.pid"

# PostgreSQL uses its own check
if [ -f "$STACK_DIR/postgresql/data/postmaster.pid" ]; then
    pg_pid=$(head -1 "$STACK_DIR/postgresql/data/postmaster.pid" 2>/dev/null || true)
    if [ -n "$pg_pid" ] && kill -0 "$pg_pid" 2>/dev/null; then
        still_running+=("PostgreSQL (PID $pg_pid)")
    fi
fi

if [ ${#still_running[@]} -gt 0 ]; then
    log_warn "The following services are still running:"
    for svc in "${still_running[@]}"; do
        log_warn "  • $svc"
    done
    echo ""
    read -p "Force-kill them and continue? (yes/no) " -r FORCE
    if [ "$FORCE" != "yes" ]; then
        log_info "Uninstall aborted. Stop the services manually and re-run."
        exit 1
    fi
    # Force kill
    for svc in "${still_running[@]}"; do
        pid=$(echo "$svc" | grep -oP 'PID \K[0-9]+' || true)
        [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null || true
    done
    sleep 1
fi

# ── Remove the stack directory ───────────────────────────────────────────────
log_info "Removing stack directory: $STACK_DIR"

# Calculate size for reporting
STACK_SIZE="unknown"
if command -v du &>/dev/null; then
    STACK_SIZE=$(du -sh "$STACK_DIR" 2>/dev/null | cut -f1 || echo "unknown")
fi

rm -rf "$STACK_DIR"
log_info "Removed $STACK_DIR (~$STACK_SIZE freed)"

# ── Remove symlinks from ~/.local/bin ────────────────────────────────────────
log_info "Removing symlinks from ~/.local/bin ..."

SYMLINKS=(
    webstack-start
    webstack-stop
    webstack-php
    webstack-mysql
    webstack-psql
)

for link in "${SYMLINKS[@]}"; do
    target="$HOME/.local/bin/$link"
    if [ -L "$target" ]; then
        rm -f "$target"
        log_info "  Removed $target"
    fi
done

# ── Remove desktop entry ─────────────────────────────────────────────────────
DESKTOP_FILE="$HOME/.local/share/applications/webstack-manager.desktop"
if [ -f "$DESKTOP_FILE" ]; then
    rm -f "$DESKTOP_FILE"
    log_info "Removed desktop entry"
    # Refresh app menu if possible
    command -v update-desktop-database &>/dev/null && \
        update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
fi

# ── Remove shell PATH additions added by the installer ──────────────────────
log_info "Cleaning shell configuration files..."

# The installer appends exactly this line pattern; remove it safely
SHELL_FILES=("$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile")
PATTERN='export PATH="\$HOME/.local/bin:\$PATH"'

for rc in "${SHELL_FILES[@]}"; do
    if [ -f "$rc" ] && grep -qF "$PATTERN" "$rc"; then
        # Create a backup then strip the line
        cp "$rc" "${rc}.webstack.bak"
        grep -vF "$PATTERN" "$rc" > "${rc}.tmp" && mv "${rc}.tmp" "$rc"
        log_info "  Cleaned $rc (backup at ${rc}.webstack.bak)"
    fi
done

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "========================================"
echo "  WebStack uninstalled successfully."
echo "========================================"
echo ""
log_info "Freed approximately $STACK_SIZE of disk space."
echo ""
echo "If you sourced env.sh in your current shell session, open a new"
echo "terminal to ensure no stale environment variables remain."
echo ""
