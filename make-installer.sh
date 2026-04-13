#!/bin/bash
# make-installer.sh
# ─────────────────────────────────────────────────────────────────────────────
# Packages a compiled ~/webstack directory into a single self-extracting
# installer .run file.  Run this on the machine where you built the stack.
#
# Usage:
#   bash make-installer.sh [options]
#
# Options:
#   -s, --source DIR      Source webstack directory  (default: ~/webstack)
#   -o, --output FILE     Output installer filename  (default: ./webstack-installer.run)
#   -j, --jobs N          xz compression threads     (default: all cores)
#   --compression N       xz compression level 0-9   (default: 6)
#   --no-strip            Skip stripping debug symbols
#   --no-prune            Skip removing build/download dirs and static libs
#   --keep-tmp            Keep the temporary staging directory after build
#   -h, --help            Show this help
#
# Requirements on the build machine:  bash, tar, xz, find, sed, file
# Requirements on the target machine: bash, tar, xz
# Optional on target:                 patchelf (for full RPATH rewrite)
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[make-installer]${NC} $1"; }
warn() { echo -e "${YELLOW}[make-installer]${NC} $1"; }
err()  { echo -e "${RED}[make-installer]${NC} $1" >&2; }
step() { echo -e "${CYAN}[make-installer]${NC} ── $1"; }

# ── Defaults ─────────────────────────────────────────────────────────────────
SOURCE_DIR="$HOME/webstack"
OUTPUT_FILE="./webstack-installer.run"
XZ_THREADS=$(nproc 2>/dev/null || echo 4)
XZ_LEVEL=6
DO_STRIP=true
DO_PRUNE=true
KEEP_TMP=false

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--source)      SOURCE_DIR="$2";  shift 2 ;;
        -o|--output)      OUTPUT_FILE="$2"; shift 2 ;;
        -j|--jobs)        XZ_THREADS="$2";  shift 2 ;;
        --compression)    XZ_LEVEL="$2";    shift 2 ;;
        --no-strip)       DO_STRIP=false;   shift   ;;
        --no-prune)       DO_PRUNE=false;   shift   ;;
        --keep-tmp)       KEEP_TMP=true;    shift   ;;
        -h|--help)
            sed -n '2,25p' "$0" | sed 's/^# \?//'
            exit 0 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

SOURCE_DIR="$(realpath "$SOURCE_DIR")"
OUTPUT_FILE="$(realpath "$OUTPUT_FILE")"

# ── Validate source ───────────────────────────────────────────────────────────
if [ ! -d "$SOURCE_DIR" ]; then
    err "Source directory not found: $SOURCE_DIR"
    err "Build the stack first with: bash install-webstack.sh"
    exit 1
fi

for required in nginx/nginx mariadb/bin/mariadbd postgresql/bin/pg_ctl; do
    if [ ! -f "$SOURCE_DIR/$required" ] && [ ! -L "$SOURCE_DIR/$required" ]; then
        warn "Expected binary missing: $SOURCE_DIR/$required"
        warn "The stack may not be fully built."
    fi
done

# Check required tools on this machine
for tool in tar xz find sed file base64; do
    if ! command -v "$tool" &>/dev/null; then
        err "Required tool not found: $tool"
        exit 1
    fi
done

# ── Staging area ──────────────────────────────────────────────────────────────
TMP_DIR=$(mktemp -d /tmp/webstack-pkg.XXXXXX)
STAGE="$TMP_DIR/webstack"

cleanup() {
    if [ "$KEEP_TMP" = false ]; then
        rm -rf "$TMP_DIR"
    else
        log "Temporary staging dir kept at: $TMP_DIR"
    fi
}
trap cleanup EXIT

log "Source:  $SOURCE_DIR"
log "Output:  $OUTPUT_FILE"
log "Staging: $STAGE"
echo ""

# ── Step 1: Copy to staging ───────────────────────────────────────────────────
step "Copying webstack to staging area ..."
# Exclude the build/ and downloads/ dirs up-front during copy to save I/O
rsync -a --delete \
    --exclude='/build/' \
    --exclude='/downloads/' \
    --exclude='/.build_status' \
    "$SOURCE_DIR/" "$STAGE/" 2>/dev/null || \
cp -a "$SOURCE_DIR/." "$STAGE/"

# Manually remove build and downloads if rsync wasn't available
rm -rf "$STAGE/build" "$STAGE/downloads" "$STAGE/.build_status"

# ── Step 2: Prune runtime-unnecessary files ───────────────────────────────────
if [ "$DO_PRUNE" = true ]; then
    step "Pruning static libs, headers, and libtool files ..."
    # Static libs are only needed at compile time
    find "$STAGE/deps/lib"         -name "*.a"  -delete 2>/dev/null || true
    find "$STAGE/deps/lib"         -name "*.la" -delete 2>/dev/null || true
    find "$STAGE/postgresql/lib"   -name "*.a"  -delete 2>/dev/null || true
    # Headers not needed at runtime
    rm -rf "$STAGE/deps/include"
    rm -rf "$STAGE/postgresql/include"
    # cmake and pkgconfig tools not needed at runtime
    rm -rf "$STAGE/deps/lib/cmake"
    rm -f  "$STAGE/deps/bin/cmake" "$STAGE/deps/bin/ctest" "$STAGE/deps/bin/cpack"
    log "Pruning complete."
fi

# ── Step 3: Strip debug symbols ───────────────────────────────────────────────
if [ "$DO_STRIP" = true ]; then
    step "Stripping debug symbols from ELF binaries ..."
    STRIPPED=0
    FAILED=0
    while IFS= read -r f; do
        if file "$f" 2>/dev/null | grep -qE 'ELF.*(executable|shared object)'; then
            if strip --strip-unneeded "$f" 2>/dev/null; then
                (( STRIPPED++ )) || true
            else
                (( FAILED++ )) || true
            fi
        fi
    done < <(find "$STAGE" -type f \( -name "*.so*" -o -perm /0111 \) \
                 ! -name "*.php" ! -name "*.py" ! -name "*.sh" ! -name "*.ini" \
                 ! -name "*.conf" ! -name "*.cnf" ! -path "*/etc/*")
    log "Stripped $STRIPPED binaries ($FAILED skipped)."
fi

# ── Step 4: Record the build prefix so relocate.sh knows what to replace ──────
BUILD_PREFIX="$SOURCE_DIR"
step "Recording build prefix: $BUILD_PREFIX"
echo "$BUILD_PREFIX" > "$STAGE/.build_prefix"

# ── Step 5: Inject relocate.sh ────────────────────────────────────────────────
step "Writing relocate.sh ..."
cat > "$STAGE/relocate.sh" << 'RELOCATE_OUTER'
#!/bin/bash
# relocate.sh — run automatically by the installer after extraction.
# Rewrites every hardcoded build-time path to the new install location.
# Safe to re-run if the stack is moved again.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX_FILE="$SCRIPT_DIR/.build_prefix"

if [ ! -f "$PREFIX_FILE" ]; then
    echo "ERROR: .build_prefix file missing — cannot determine old path." >&2
    exit 1
fi

OLD_PREFIX="$(cat "$PREFIX_FILE")"
NEW_PREFIX="$SCRIPT_DIR"

if [ "$OLD_PREFIX" = "$NEW_PREFIX" ]; then
    echo "Path unchanged ($NEW_PREFIX) — nothing to relocate."
    exit 0
fi

echo "Relocating: $OLD_PREFIX → $NEW_PREFIX"

# ── 1. Rewrite RPATH in ELF binaries ─────────────────────────────────────────
if command -v patchelf &>/dev/null; then
    echo "  Rewriting ELF RPATHs with patchelf ..."
    PATCHED=0
    while IFS= read -r f; do
        OLD_RPATH="$(patchelf --print-rpath "$f" 2>/dev/null || true)"
        if [[ "$OLD_RPATH" == *"$OLD_PREFIX"* ]]; then
            NEW_RPATH="${OLD_RPATH//$OLD_PREFIX/$NEW_PREFIX}"
            patchelf --set-rpath "$NEW_RPATH" "$f" 2>/dev/null && (( PATCHED++ )) || true
        fi
    done < <(find "$NEW_PREFIX" -type f ! -name "*.py" ! -name "*.sh" ! -name "*.php")
    echo "  Patched $PATCHED ELF binaries."
else
    echo "  WARNING: patchelf not found. ELF RPATHs not updated."
    echo "  Binaries will still work if installed at: $OLD_PREFIX"
    echo "  Or install patchelf and re-run: bash $NEW_PREFIX/relocate.sh"
    echo "  Falling back to LD_LIBRARY_PATH in env.sh ..."
    # Write LD_LIBRARY_PATH into env.sh as fallback
    if [ -f "$NEW_PREFIX/env.sh" ]; then
        if ! grep -q "LD_LIBRARY_PATH" "$NEW_PREFIX/env.sh"; then
            echo "export LD_LIBRARY_PATH=\"$NEW_PREFIX/deps/lib:\$LD_LIBRARY_PATH\"" >> "$NEW_PREFIX/env.sh"
        fi
    fi
fi

# ── 2. Rewrite text configs, scripts, pkg-config files ───────────────────────
echo "  Rewriting text files ..."
TEXT_COUNT=0
while IFS= read -r f; do
    if grep -qF "$OLD_PREFIX" "$f" 2>/dev/null; then
        sed -i "s|${OLD_PREFIX}|${NEW_PREFIX}|g" "$f"
        (( TEXT_COUNT++ )) || true
    fi
done < <(find "$NEW_PREFIX" -type f \( \
    -name "*.sh"   -o -name "*.conf" -o -name "*.cnf"  -o \
    -name "*.pc"   -o -name "*.ini"  -o -name "*.cmake" -o \
    -name "env.sh" -o -name "my.cnf" -o -name "nginx.conf" \
\))
echo "  Updated $TEXT_COUNT text files."

# ── 3. Rewrite PostgreSQL data directory configs ──────────────────────────────
for pgfile in \
    "$NEW_PREFIX/postgresql/data/postgresql.conf" \
    "$NEW_PREFIX/postgresql/data/pg_hba.conf" \
    "$NEW_PREFIX/postgresql/data/pg_ident.conf"
do
    if [ -f "$pgfile" ] && grep -qF "$OLD_PREFIX" "$pgfile" 2>/dev/null; then
        sed -i "s|${OLD_PREFIX}|${NEW_PREFIX}|g" "$pgfile"
    fi
done

# ── 4. Rewrite php.ini and conf.d files for all PHP versions ─────────────────
find "$NEW_PREFIX/php" -name "php.ini" -o -name "*.ini" 2>/dev/null | while IFS= read -r f; do
    if grep -qF "$OLD_PREFIX" "$f" 2>/dev/null; then
        sed -i "s|${OLD_PREFIX}|${NEW_PREFIX}|g" "$f"
    fi
done

# ── 5. Recreate ~/.local/bin symlinks pointing to the new location ────────────
LOCAL_BIN="$HOME/.local/bin"
mkdir -p "$LOCAL_BIN"
declare -A LINKS=(
    [webstack-start]="bin/start.sh"
    [webstack-stop]="bin/stop.sh"
    [webstack-php]="bin/switch-php.sh"
    [webstack-mysql]="bin/mysql.sh"
    [webstack-psql]="bin/psql.sh"
)
for name in "${!LINKS[@]}"; do
    target="$NEW_PREFIX/${LINKS[$name]}"
    if [ -f "$target" ]; then
        ln -sf "$target" "$LOCAL_BIN/$name"
    fi
done

# ── 6. Update .build_prefix to reflect the new location ──────────────────────
echo "$NEW_PREFIX" > "$NEW_PREFIX/.build_prefix"

echo ""
echo "Relocation complete."
echo "  Install path : $NEW_PREFIX"
echo "  Run: source $NEW_PREFIX/env.sh && webstack-start"
echo ""
RELOCATE_OUTER

chmod +x "$STAGE/relocate.sh"

# ── Step 6: Pack the tarball ──────────────────────────────────────────────────
TARBALL="$TMP_DIR/payload.tar.xz"
step "Packing tarball (xz -${XZ_LEVEL} -T${XZ_THREADS}) — this may take a few minutes ..."
BEFORE_SIZE=$(du -sh "$STAGE" 2>/dev/null | cut -f1)

# XZ_OPT is the portable way to pass flags to xz regardless of tar version.
# --options "xz:..." is a GNU tar extension not available everywhere.
XZ_OPT="-${XZ_LEVEL} -T${XZ_THREADS}" tar -C "$TMP_DIR" --xz -cf "$TARBALL" "webstack"

TARBALL_SIZE=$(du -sh "$TARBALL" | cut -f1)
log "Payload: $BEFORE_SIZE → $TARBALL_SIZE (compressed)"

# ── Step 7: Build the self-extracting shell header ────────────────────────────
step "Building self-extracting installer ..."

# We write the header to a temp file first then concatenate the binary payload.
HEADER_FILE="$TMP_DIR/header.sh"

# Embed the build prefix so the installer can show what path needs relocating.
ENCODED_PREFIX=$(echo "$BUILD_PREFIX" | base64 -w0)

cat > "$HEADER_FILE" << HEADER_EOF
#!/bin/bash
# WebStack Self-Extracting Installer (.run)
# Built: $(date -u '+%Y-%m-%d %H:%M UTC')
# Source: $BUILD_PREFIX
#
# Usage:
#   ./webstack-installer.run
#   WEBSTACK_INSTALL_DIR=/custom/path ./webstack-installer.run
#
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "\${GREEN}[WebStack]\${NC} \$1"; }
warn() { echo -e "\${YELLOW}[WebStack]\${NC} \$1"; }
err()  { echo -e "\${RED}[WebStack]\${NC} \$1" >&2; }

BUILD_PREFIX="\$(echo '$ENCODED_PREFIX' | base64 -d)"
INSTALL_DIR="\${WEBSTACK_INSTALL_DIR:-\$HOME/webstack}"

echo ""
echo -e "\${CYAN}╔══════════════════════════════════════════════════╗\${NC}"
echo -e "\${CYAN}║         WebStack Installer                       ║\${NC}"
echo -e "\${CYAN}║  Nginx · PHP 8.2/8.3/8.4 · MariaDB · PostgreSQL ║\${NC}"
echo -e "\${CYAN}╚══════════════════════════════════════════════════╝\${NC}"
echo ""
echo "  Install path : \$INSTALL_DIR"
echo "  Built from   : \$BUILD_PREFIX"
echo "  Override     : WEBSTACK_INSTALL_DIR=/your/path ./\$(basename \$0)"
echo ""

# ── Preflight checks ──────────────────────────────────────────────────────────
for tool in tar xz bash; do
    if ! command -v "\$tool" &>/dev/null; then
        err "Required tool not found: \$tool"
        err "Install it and re-run."
        exit 1
    fi
done

FREESPACE=\$(df -BG "\$(dirname \$INSTALL_DIR)" 2>/dev/null | awk 'NR==2{gsub(/G/,"",\$4); print \$4}' || echo 99)
if [ "\${FREESPACE:-99}" -lt 3 ] 2>/dev/null; then
    warn "Low disk space (\${FREESPACE}GB free). WebStack needs ~2-4 GB."
fi

# ── Handle existing installation ──────────────────────────────────────────────
if [ -d "\$INSTALL_DIR" ]; then
    warn "Directory already exists: \$INSTALL_DIR"
    # Check if services are running
    RUNNING=()
    [ -f "\$INSTALL_DIR/nginx/nginx.pid" ] && kill -0 \$(cat "\$INSTALL_DIR/nginx/nginx.pid") 2>/dev/null && RUNNING+=("Nginx")
    [ -f "\$INSTALL_DIR/postgresql/data/postmaster.pid" ] && kill -0 \$(head -1 "\$INSTALL_DIR/postgresql/data/postmaster.pid") 2>/dev/null && RUNNING+=("PostgreSQL")
    [ -f "\$INSTALL_DIR/mariadb/mariadb.pid" ] && kill -0 \$(cat "\$INSTALL_DIR/mariadb/mariadb.pid") 2>/dev/null && RUNNING+=("MariaDB")
    if [ \${#RUNNING[@]} -gt 0 ]; then
        err "Services are still running: \${RUNNING[*]}"
        err "Stop them first: webstack-stop  (or: bash \$INSTALL_DIR/bin/stop.sh)"
        exit 1
    fi
    read -p "Overwrite existing installation? (yes/no) " -r CONFIRM
    [ "\$CONFIRM" != "yes" ] && { log "Installation cancelled."; exit 0; }
    rm -rf "\$INSTALL_DIR"
fi

mkdir -p "\$(dirname \$INSTALL_DIR)"

# ── Extract payload ───────────────────────────────────────────────────────────
log "Extracting payload ..."
PAYLOAD_START=\$(awk '/^__PAYLOAD_START__\$/{print NR+1; exit}' "\$0")
if [ -z "\$PAYLOAD_START" ]; then
    err "Payload marker not found — installer file may be corrupted."
    exit 1
fi

EXTRACT_DIR="\$(dirname \$INSTALL_DIR)"
tail -n +"\$PAYLOAD_START" "\$0" | base64 -d | tar -xJ -C "\$EXTRACT_DIR"

# The tarball extracts as a directory named "webstack"; rename if needed
EXTRACTED="\$EXTRACT_DIR/webstack"
if [ -d "\$EXTRACTED" ] && [ "\$EXTRACTED" != "\$INSTALL_DIR" ]; then
    mv "\$EXTRACTED" "\$INSTALL_DIR"
fi

if [ ! -d "\$INSTALL_DIR" ]; then
    err "Extraction failed — directory not created: \$INSTALL_DIR"
    exit 1
fi
log "Extracted to: \$INSTALL_DIR"

# ── Relocate paths ────────────────────────────────────────────────────────────
if [ "\$BUILD_PREFIX" != "\$INSTALL_DIR" ]; then
    log "Relocating from build path to install path ..."
    bash "\$INSTALL_DIR/relocate.sh"
else
    log "Install path matches build path — skipping relocation."
fi

# ── Wire up shell integrations ────────────────────────────────────────────────
LOCAL_BIN="\$HOME/.local/bin"
EXPORT_LINE='export PATH="\$HOME/.local/bin:\$PATH"'
for RC in "\$HOME/.bashrc" "\$HOME/.zshrc"; do
    if [ -f "\$RC" ] && ! grep -qF 'local/bin' "\$RC"; then
        { echo ""; echo "# WebStack"; echo "\$EXPORT_LINE"; } >> "\$RC"
        log "Added ~/.local/bin to PATH in \$(basename \$RC)"
    fi
done

# ── Desktop entry (optional) ──────────────────────────────────────────────────
DESKTOP_DIR="\$HOME/.local/share/applications"
if python3 -c "import PySide6" 2>/dev/null && [ -f "\$INSTALL_DIR/cp.py" ]; then
    mkdir -p "\$DESKTOP_DIR"
    cat > "\$DESKTOP_DIR/webstack-manager.desktop" << DESKTOP
[Desktop Entry]
Name=WebStack Manager
Comment=Manage Nginx, PHP, MariaDB and PostgreSQL
Exec=python3 \$INSTALL_DIR/cp.py
Terminal=false
Type=Application
Categories=Development;WebDevelopment;
DESKTOP
    update-desktop-database "\$DESKTOP_DIR" 2>/dev/null || true
    log "Desktop entry installed."
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "\${GREEN}══════════════════════════════════════════════════\${NC}"
log "WebStack installed successfully!"
echo ""
echo "  \${CYAN}webstack-start\${NC}        — start all services"
echo "  \${CYAN}webstack-stop\${NC}         — stop all services"
echo "  \${CYAN}webstack-php VER\${NC}      — switch PHP version (8.2 / 8.3 / 8.4)"
echo "  \${CYAN}webstack-mysql\${NC}        — MariaDB client"
echo "  \${CYAN}webstack-psql\${NC}         — PostgreSQL client"
echo "                          (user: postgres  password: 123456)"
echo ""
echo "  Web root : \$INSTALL_DIR/www"
echo "  URL      : http://localhost:8080"
echo ""
echo "  PHP settings override: \$INSTALL_DIR/php/<ver>/etc/conf.d/webstack.ini"
echo ""
if [ "\$PATH" != *"\$LOCAL_BIN"* ]; then
    echo -e "  \${YELLOW}Open a new terminal or run:  source ~/.bashrc\${NC}"
fi
echo -e "\${GREEN}══════════════════════════════════════════════════\${NC}"
echo ""
exit 0
__PAYLOAD_START__
HEADER_EOF

# ── Step 8: Concatenate header + base64 payload ───────────────────────────────
step "Concatenating header and base64 payload ..."
cat "$HEADER_FILE" > "$OUTPUT_FILE"
base64 -w76 "$TARBALL" >> "$OUTPUT_FILE"
chmod +x "$OUTPUT_FILE"

# ── Step 9: Verify the installer ──────────────────────────────────────────────
step "Verifying installer integrity ..."
PAYLOAD_LINE=$(awk '/^__PAYLOAD_START__$/{print NR+1; exit}' "$OUTPUT_FILE")
if [ -z "$PAYLOAD_LINE" ]; then
    err "Verification failed: payload marker not found in output file."
    exit 1
fi
# Decode the payload and check the tarball is valid
if tail -n +"$PAYLOAD_LINE" "$OUTPUT_FILE" | base64 -d | tar -tJ &>/dev/null; then
    log "Payload verified — tarball is valid inside the installer."
else
    err "Verification failed: embedded tarball is corrupt."
    exit 1
fi

# ── Summary ───────────────────────────────────────────────────────────────────
FINAL_SIZE=$(du -sh "$OUTPUT_FILE" | cut -f1)
echo ""
echo "════════════════════════════════════════════"
log "Installer ready: $OUTPUT_FILE"
log "Size: $FINAL_SIZE"
echo ""
echo "  Test locally:     ./webstack-installer.run"
echo "  Custom location:  WEBSTACK_INSTALL_DIR=~/mystack ./webstack-installer.run"
echo "  Copy to another machine and run the same command."
echo "════════════════════════════════════════════"
echo ""
