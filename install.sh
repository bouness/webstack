#!/bin/bash

# Linux Universal Isolated Web Stack Installer
# Phase 1: Compile to /opt/webstack (fixed path, rpath target)
# Phase 2: Per-user setup in ~/.webstack/ and ~/webstack-www/
#
# ⚠️  DO NOT run with sudo. The script calls sudo internally
#     only when needed (creating /opt/webstack).

set -e

BUILD_ONLY=0
PHASE2_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --build-only)   BUILD_ONLY=1 ;;
        --phase2-only)  PHASE2_ONLY=1 ;;
    esac
done

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "${BLUE}[STEP]${NC} $1"; }

# ══════════════════════════════════════════════════════════════════════════════
#  ABSOLUTE REFUSAL TO RUN AS ROOT
# ══════════════════════════════════════════════════════════════════════════════
if [ "$EUID" -eq 0 ]; then
    log_error "═══════════════════════════════════════════════════"
    log_error "  DO NOT run this script with sudo or as root!"
    log_error "═══════════════════════════════════════════════════"
    echo ""
    if [ -n "$SUDO_USER" ]; then
        log_info "You ran:  sudo bash $0"
        log_info "Instead:  bash $0"
    else
        log_info "You are running as root. Switch to your user first."
        log_info "Instead:  su - <username> && bash $0"
    fi
    echo ""
    log_info "The script calls sudo internally ONLY to create /opt/webstack."
    log_info "Everything else (building, Phase 2 user setup) runs as your user."
    echo ""
    if [ -n "$SUDO_USER" ] && [ -n "$SUDO_COMMAND" ]; then
        log_info "Auto-relaunching as $SUDO_USER..."
        exec su - "$SUDO_USER" -c "bash '$(readlink -f "$0")'"
    fi
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
#  PATHS
# ══════════════════════════════════════════════════════════════════════════════
INSTALL_DIR="/opt/webstack"
DEPS_DIR="$INSTALL_DIR/deps"
BUILD_DIR="$INSTALL_DIR/build"
DOWNLOAD_DIR="$INSTALL_DIR/downloads"
USER_DIR="$HOME/.webstack"
USER_WWW="$HOME/webstack-www"
NPROC=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)

# ── Version config ───────────────────────────────────────────────────────────
PHP_VERSIONS=("8.5.5" "8.4.20" "8.3.30")
NGINX_VERSION="1.28.3"
MARIADB_VERSION="11.8.6"
POSTGRESQL_VERSION="17.9"
OPENSSL_VERSION="3.6.2"
PCRE2_VERSION="10.47"
ZLIB_VERSION="1.3.2"
LIBXML2_VERSION="2.15.3"
CURL_VERSION="8.19.0"
ONIGURUMA_VERSION="6.9.10"
SQLITE_YEAR="2026"
SQLITE_VERSION="3530000"
LIBZIP_VERSION="1.11.4"
LIBPNG_VERSION="1.6.58"
LIBJPEG_VERSION="3.1.0"
FREETYPE_VERSION="2.14.3"
ICU_VERSION="78.1"
NCURSES_VERSION="6.6"
LIBAIO_VERSION="0.3.113"
CMAKE_VERSION="4.3.1"
SODIUM_VERSION="1.0.22"
LIBXSLT_VERSION="1.1.45"

# ── Distro detection ─────────────────────────────────────────────────────────
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
#  ENVIRONMENT MANAGEMENT
# ══════════════════════════════════════════════════════════════════════════════
setup_build_flags() {
    export PKG_CONFIG_LIBDIR="$DEPS_DIR/lib/pkgconfig:$DEPS_DIR/share/pkgconfig"
    unset PKG_CONFIG_PATH
    export PATH="$DEPS_DIR/bin:$PATH"
    export CPPFLAGS="-I$DEPS_DIR/include"
    export LDFLAGS="-L$DEPS_DIR/lib -Wl,-rpath,$DEPS_DIR/lib -Wl,--as-needed"
    export CFLAGS="-O2"
    export CXXFLAGS="-O2"
    unset LD_LIBRARY_PATH ACLOCAL_PATH
}

with_system_env() {
    local _cpp="$CPPFLAGS" _cxx="$CXXFLAGS" _ldf="$LDFLAGS" _cfl="$CFLAGS"
    local _pcl="$PKG_CONFIG_LIBDIR" _pcp="$PKG_CONFIG_PATH" _ac="$ACLOCAL_PATH"
    unset CPPFLAGS CXXFLAGS LDFLAGS CFLAGS PKG_CONFIG_LIBDIR PKG_CONFIG_PATH ACLOCAL_PATH
    "$@"
    local ret=$?
    export CPPFLAGS="$_cpp" CXXFLAGS="$_cxx" LDFLAGS="$_ldf" CFLAGS="$_cfl"
    export PKG_CONFIG_LIBDIR="$_pcl" PKG_CONFIG_PATH="$_pcp" ACLOCAL_PATH="$_ac"
    return $ret
}

# ══════════════════════════════════════════════════════════════════════════════
#  BUILD TOOL INSTALLER
# ══════════════════════════════════════════════════════════════════════════════
check_and_install_build_tools() {
    log_step "Checking for required build tools..."
    local required_cmds=(gcc g++ make perl pkg-config tar)
    local optional_cmds=(wget curl xz autoconf automake libtool bison)
    local missing_req=() missing_opt=()

    for cmd in "${required_cmds[@]}"; do
        command -v "$cmd" &>/dev/null || missing_req+=("$cmd")
    done
    for cmd in "${optional_cmds[@]}"; do
        command -v "$cmd" &>/dev/null || missing_opt+=("$cmd")
    done
    if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
        missing_req+=(wget)
    fi
    if [ ! -f /etc/ssl/certs/ca-certificates.crt ] && \
       [ ! -f /etc/pki/tls/certs/ca-bundle.crt ] && \
       ! ls /etc/ssl/certs/*.pem 2>/dev/null | head -1 | grep -q .; then
        missing_req+=(ca-certificates)
    fi

    [ ${#missing_req[@]} -eq 0 ] && [ ${#missing_opt[@]} -eq 0 ] && \
        { log_info "All build tools found."; return 0; }

    local pkg_list=() opt_list=() install_cmd=""

    case "$DISTRO_ID" in
        ubuntu|debian|linuxmint|pop)
            for c in "${missing_req[@]}"; do case "$c" in
                gcc) pkg_list+=(gcc);; g++) pkg_list+=(g++);; make) pkg_list+=(make);;
                perl) pkg_list+=(perl);; pkg-config) pkg_list+=(pkg-config);;
                tar) pkg_list+=(tar);; wget) pkg_list+=(wget);;
                ca-certificates) pkg_list+=(ca-certificates);; *) pkg_list+=("$c");;
            esac; done
            for c in "${missing_opt[@]}"; do case "$c" in
                xz) opt_list+=(xz-utils);; libtool) opt_list+=(libtool-bin);; *) opt_list+=("$c");;
            esac; done
            install_cmd="sudo apt-get update && sudo apt-get install -y"
            ;;
        fedora|rhel|centos|rocky|alma)
            for c in "${missing_req[@]}"; do case "$c" in
                gcc) pkg_list+=(gcc);; g++) pkg_list+=(gcc-c++);; make) pkg_list+=(make);;
                perl) pkg_list+=(perl-interpreter);; pkg-config) pkg_list+=(pkgconfig);;
                tar) pkg_list+=(tar);; wget) pkg_list+=(wget);;
                ca-certificates) pkg_list+=(ca-certificates);; *) pkg_list+=("$c");;
            esac; done
            opt_list=("${missing_opt[@]}")
            install_cmd="sudo dnf install -y"
            ;;
        arch|manjaro|cachyos|endeavouros)
            for c in "${missing_req[@]}"; do case "$c" in
                g++) pkg_list+=(gcc);; pkg-config) pkg_list+=(pkg-config);;
                ca-certificates) pkg_list+=(ca-certificates);; *) pkg_list+=("$c");;
            esac; done
            for c in "${missing_opt[@]}"; do case "$c" in
                libtool) opt_list+=(libtool);; *) opt_list+=("$c");;
            esac; done
            install_cmd="sudo pacman -S --noconfirm"
            ;;
        opensuse*|sles)
            for c in "${missing_req[@]}"; do case "$c" in
                g++) pkg_list+=(gcc-c++);; pkg-config) pkg_list+=(pkg-config);;
                ca-certificates) pkg_list+=(ca-certificates);; *) pkg_list+=("$c");;
            esac; done
            opt_list=("${missing_opt[@]}")
            install_cmd="sudo zypper install -y"
            ;;
        alpine)
            for c in "${missing_req[@]}"; do case "$c" in
                g++) pkg_list+=(g++);; pkg-config) pkg_list+=(pkgconfig);;
                ca-certificates) pkg_list+=(ca-certificates);; *) pkg_list+=("$c");;
            esac; done
            opt_list=("${missing_opt[@]}")
            install_cmd="sudo apk add"
            ;;
        *)
            log_error "Unknown distro: $DISTRO_ID. Install manually:"
            echo "  ${missing_req[*]} ${missing_opt[*]}"
            exit 1 ;;
    esac

    local all_pkgs=("${pkg_list[@]+"${pkg_list[@]}"}" "${opt_list[@]+"${opt_list[@]}"}")
    log_info "Installing missing tools: ${all_pkgs[*]}"
    if command -v sudo &>/dev/null; then
        eval "$install_cmd ${all_pkgs[*]}" && {
            log_info "Build tools installed."; return 0
        } || {
            log_warn "Bulk install failed, trying individually..."
            local failed=()
            for pkg in "${all_pkgs[@]}"; do
                eval "$install_cmd $pkg" 2>/dev/null || failed+=("$pkg")
            done
            [ ${#failed[@]} -eq 0 ] && { log_info "Build tools installed."; return 0; }
            log_error "Failed: ${failed[*]}"
        }
    fi
    log_error "Cannot install build tools. Run manually:"
    echo "  $install_cmd ${all_pkgs[*]}"
    exit 1
}

# ══════════════════════════════════════════════════════════════════════════════
#  DOWNLOAD HELPERS
# ══════════════════════════════════════════════════════════════════════════════
safe_download() {
    local url=$1 filename=$2
    [ -f "$DOWNLOAD_DIR/$filename" ] && { cp "$DOWNLOAD_DIR/$filename" "$BUILD_DIR/"; return 0; }
    [ -f "$BUILD_DIR/$filename" ] && return 0
    cd "$BUILD_DIR"
    log_info "Downloading $filename..."
    with_system_env wget -q --show-progress "$url" || \
    with_system_env curl -L -o "$filename" "$url" || \
    with_system_env /usr/bin/wget -q --show-progress "$url" || \
    with_system_env /usr/bin/curl -L -o "$filename" "$url" || {
        log_error "Failed to download $filename"
        log_warn "Place it manually in: $DOWNLOAD_DIR"
        return 1
    }
    cp "$BUILD_DIR/$filename" "$DOWNLOAD_DIR/" 2>/dev/null || true
    return 0
}

download_extract() {
    local url=$1 filename; filename=$(basename "$url"); local extract_dir=$2
    cd "$BUILD_DIR"
    [ ! -f "$filename" ] && with_system_env wget -q --show-progress "$url"
    [ ! -d "$extract_dir" ] && with_system_env tar xf "$filename"
}

# ══════════════════════════════════════════════════════════════════════════════
#  BUILD TRACKING
# ══════════════════════════════════════════════════════════════════════════════
STATUS_FILE="$INSTALL_DIR/.build_status"
mark_done()  { mkdir -p "$(dirname "$STATUS_FILE")"; touch "$STATUS_FILE"; grep -q "^$1$" "$STATUS_FILE" 2>/dev/null || echo "$1" >> "$STATUS_FILE"; }
is_done()    { [ -f "$STATUS_FILE" ] && grep -q "^$1$" "$STATUS_FILE"; }
reset_done() { [ -f "$STATUS_FILE" ] && [ -n "$1" ] && sed -i "/^$1$/d" "$STATUS_FILE"; }

# ══════════════════════════════════════════════════════════════════════════════
#  PKG-CONFIG FIXUP — THE GENERAL SOLUTION
# ══════════════════════════════════════════════════════════════════════════════
#
# Problem:  .pc files contain "Requires:" and "Requires.private:" lines that
#           reference other .pc files.  If we built libcurl with --without-rtmp
#           but the generated libcurl.pc still says "Requires.private: librtmp"
#           (because the .pc.in template has conditional blocks that don't
#           always remove it cleanly, or because a system pkg-config leak
#           polluted the generated file), then PHP's configure fails with:
#
#             "Package 'librtmp', required by 'libcurl', not found"
#
#           This happens for librtmp, libpsl, libbrotli, libssh2, libidn2,
#           libnghttp2, libzstd, liblzma, and potentially many more system
#           libraries depending on the distro.  We CANNOT predict all of them.
#
# Solution: After ALL dependencies are built, scan every .pc file in our deps
#           tree.  For each Requires/Requires.private line, check whether the
#           referenced .pc file exists in our tree.  If it doesn't, remove
#           that specific requirement from the line.  This is safe because:
#
#           - We explicitly disabled these features (--without-X), so the
#             library was compiled WITHOUT that dependency.  The .pc file's
#             Requires line is stale/incorrect.
#           - For shared library linking (which PHP does), Requires.private
#             dependencies are not needed at runtime anyway — they're only
#             for static linking.
#           - If we somehow remove a REAL dependency, the linker will catch
#             it later with an undefined symbol error, which is much easier
#             to debug than a cryptic pkg-config failure.
#
# ══════════════════════════════════════════════════════════════════════════════

fixup_pkgconfig() {
    log_info "Fixing up pkg-config files..."
    local pc_dir="$DEPS_DIR/lib/pkgconfig"
    local share_pc_dir="$DEPS_DIR/share/pkgconfig"
    mkdir -p "$pc_dir" "$share_pc_dir"

    # ── Step 1: Symlink stray .pc files into lib/pkgconfig ────────────────
    while IFS= read -r -d '' pc_file; do
        local basename
        basename=$(basename "$pc_file")
        [[ "$pc_file" == "$pc_dir/$basename" ]] && continue
        [[ "$pc_file" == "$share_pc_dir/$basename" ]] && continue
        if [ ! -f "$pc_dir/$basename" ]; then
            ln -sf "$pc_file" "$pc_dir/$basename"
            log_info "  Linked: $basename <- $pc_file"
        fi
    done < <(find "$DEPS_DIR" -name '*.pc' -print0 2>/dev/null)

    # ── Step 2: Sanitize Requires lines ────────────────────────────────────
    local total_removed=0
    for dir in "$pc_dir" "$share_pc_dir"; do
        [ -d "$dir" ] || continue
        for pc_file in "$dir"/*.pc; do
            [ -f "$pc_file" ] || continue

            local tmp_file
            tmp_file=$(mktemp)
            local file_changed=0

            while IFS= read -r line || [ -n "$line" ]; do
                local keep_line=1

                # Match "Requires:" or "Requires.private:" lines
                if [[ "$line" == Requires*:* ]]; then
                    # Extract the field name and the value
                    local field_name="${line%%:*}"
                    local req_value="${line#*:}"

                    # Strip leading whitespace from value
                    req_value="${req_value#"${req_value%%[![:space:]]*}"}"

                    # Split by comma, check each dependency
                    local new_reqs=""
                    local removed_any=0
                    IFS=',' read -ra req_arr <<< "$req_value"
                    for req in "${req_arr[@]}"; do
                        # Strip whitespace
                        req="${req#"${req%%[![:space:]]*}"}"
                        req="${req%"${req##*[![:space:]]}"}"

                        # Extract package name (strip version specifiers like >= 1.0)
                        local pkg="${req%%[[:space:]]*}"
                        pkg="${pkg%%[<>=!]*}"

                        [ -z "$pkg" ] && continue

                        # Check if this .pc file exists in our deps tree
                        if [ -f "$pc_dir/$pkg.pc" ] || [ -f "$share_pc_dir/$pkg.pc" ]; then
                            # Keep this requirement
                            if [ -n "$new_reqs" ]; then
                                new_reqs="$new_reqs, $req"
                            else
                                new_reqs="$req"
                            fi
                        else
                            log_warn "  $(basename "$pc_file"): removing '$pkg' (not in deps)"
                            removed_any=1
                            total_removed=$((total_removed + 1))
                        fi
                    done

                    if [ "$removed_any" -eq 1 ]; then
                        file_changed=1
                        if [ -n "$new_reqs" ]; then
                            echo "$field_name: $new_reqs" >> "$tmp_file"
                        else
                            # Empty Requires line — still write the field so
                            # pkg-config doesn't fall back to defaults
                            echo "$field_name:" >> "$tmp_file"
                        fi
                    else
                        echo "$line" >> "$tmp_file"
                    fi
                else
                    echo "$line" >> "$tmp_file"
                fi
            done < "$pc_file"

            if [ "$file_changed" -eq 1 ]; then
                mv "$tmp_file" "$pc_file"
            else
                rm -f "$tmp_file"
            fi
        done
    done

    if [ "$total_removed" -gt 0 ]; then
        log_info "  Removed $total_removed stale dependency references from .pc files"
    fi

    # ── Step 3: Verify critical .pc files ─────────────────────────────────
    local missing=()
    for pkg in openssl libssl libcrypto libcurl libxml-2.0 libxslt libpng16 \
               libjpeg oniguruma sqlite3 libzip libpq freetype2 \
               icu-uc icu-i18n libsodium pcre2-8 zlib; do
        if [ ! -f "$pc_dir/$pkg.pc" ] && [ ! -f "$share_pc_dir/$pkg.pc" ]; then
            missing+=("$pkg")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        log_warn "Missing pkg-config files: ${missing[*]}"
        log_warn "Some PHP extensions may fail to configure."
    else
        log_info "  All critical pkg-config files present."
    fi
}

# ══════════════════════════════════════════════════════════════════════════════
#  DEPENDENCY BUILDERS
# ══════════════════════════════════════════════════════════════════════════════

build_cmake() {
    is_done "cmake" && { log_info "CMake ready — skipping"; return 0; }
    log_info "Setting up CMake..."
    if command -v cmake &>/dev/null; then
        local sv; sv=$(with_system_env cmake --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
        if [ -n "$sv" ]; then
            local sm=${sv%%.*} sn=${sv#*.}
            [ "$sm" -gt 3 ] || { [ "$sm" -eq 3 ] && [ "${sn%%.*}" -ge 13 ]; } && {
                log_info "Using system cmake $sv"
                mkdir -p "$DEPS_DIR/bin"
                ln -sf "$(with_system_env which cmake)" "$DEPS_DIR/bin/cmake"
                mark_done "cmake"; return 0
            }
        fi
    fi
    local fn="cmake-$CMAKE_VERSION-linux-x86_64.tar.gz"
    if safe_download "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/$fn" "$fn"; then
        cd "$BUILD_DIR"
        [ ! -d "cmake-$CMAKE_VERSION-linux-x86_64" ] && with_system_env tar -xzf "$fn"
        if with_system_env "$BUILD_DIR/cmake-$CMAKE_VERSION-linux-x86_64/bin/cmake" --version &>/dev/null; then
            cp -r "$BUILD_DIR/cmake-$CMAKE_VERSION-linux-x86_64"/* "$DEPS_DIR/"
            mark_done "cmake"; log_info "Prebuilt CMake installed"; return 0
        fi
    fi
    log_info "Building CMake from source (~10 min)..."
    local sf="cmake-$CMAKE_VERSION.tar.gz"
    safe_download "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/$sf" "$sf" || return 1
    cd "$BUILD_DIR"; [ ! -d "cmake-$CMAKE_VERSION" ] && with_system_env tar -xzf "$sf"
    cd "$BUILD_DIR/cmake-$CMAKE_VERSION"
    with_system_env ./bootstrap --prefix="$DEPS_DIR" --parallel="$NPROC" && \
    make -j"$NPROC" && make install && {
        mark_done "cmake"; log_info "CMake built from source"; return 0
    }
    log_error "All CMake strategies failed"; return 1
}

build_zlib() {
    is_done "zlib" && return 0
    log_info "Building zlib $ZLIB_VERSION..."
    safe_download "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz" "zlib-$ZLIB_VERSION.tar.gz" || \
    safe_download "https://www.zlib.net/zlib-$ZLIB_VERSION.tar.gz" "zlib-$ZLIB_VERSION.tar.gz" || return 1
    cd "$BUILD_DIR"; [ ! -d "zlib-$ZLIB_VERSION" ] && with_system_env tar -xzf "zlib-$ZLIB_VERSION.tar.gz"
    cd "$BUILD_DIR/zlib-$ZLIB_VERSION"
    ./configure --prefix="$DEPS_DIR" --libdir="$DEPS_DIR/lib" && make -j"$NPROC" && make install && mark_done "zlib"
}

build_sodium() {
    is_done "sodium" && return 0
    log_info "Building libsodium $SODIUM_VERSION..."
    # Primary: official download site. Fallback: GitHub (tag has -RELEASE suffix).
    safe_download "https://download.libsodium.org/libsodium/releases/libsodium-$SODIUM_VERSION.tar.gz" "libsodium-$SODIUM_VERSION.tar.gz" || \
    safe_download "https://github.com/jedisct1/libsodium/releases/download/${SODIUM_VERSION}-RELEASE/libsodium-$SODIUM_VERSION.tar.gz" "libsodium-$SODIUM_VERSION.tar.gz" || return 1
    cd "$BUILD_DIR"; [ ! -d "libsodium-$SODIUM_VERSION" ] && with_system_env tar -xzf "libsodium-$SODIUM_VERSION.tar.gz"
    cd "$BUILD_DIR/libsodium-$SODIUM_VERSION"
    ./configure --prefix="$DEPS_DIR" --libdir="$DEPS_DIR/lib" --disable-shared --enable-static && \
    make -j"$NPROC" && make install && mark_done "sodium"
}

build_openssl() {
    is_done "openssl" && return 0
    log_info "Building OpenSSL $OPENSSL_VERSION..."
    safe_download "https://www.openssl.org/source/openssl-$OPENSSL_VERSION.tar.gz" "openssl-$OPENSSL_VERSION.tar.gz" || return 1
    cd "$BUILD_DIR"; [ ! -d "openssl-$OPENSSL_VERSION" ] && with_system_env tar -xzf "openssl-$OPENSSL_VERSION.tar.gz"
    cd "$BUILD_DIR/openssl-$OPENSSL_VERSION"
    # --libdir=lib: CRITICAL — prevents multiarch detection putting .pc
    # files in lib/x86_64-linux-gnu/pkgconfig/ on Ubuntu/Debian
    ./config --prefix="$DEPS_DIR" --openssldir="$DEPS_DIR/ssl" --libdir=lib shared zlib && \
    make -j"$NPROC" && make install_sw || { log_error "OpenSSL build failed"; return 1; }
    if [ ! -f "$DEPS_DIR/lib/pkgconfig/openssl.pc" ]; then
        local found; found=$(find "$DEPS_DIR" -name 'openssl.pc' 2>/dev/null | head -1)
        if [ -n "$found" ]; then
            mkdir -p "$DEPS_DIR/lib/pkgconfig"
            ln -sf "$found" "$DEPS_DIR/lib/pkgconfig/openssl.pc"
            log_info "  Linked openssl.pc from $found"
        else
            log_error "openssl.pc not found anywhere"; return 1
        fi
    fi
    mark_done "openssl"
}

build_pcre2() {
    is_done "pcre2" && return 0
    log_info "Building PCRE2 $PCRE2_VERSION..."
    safe_download "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/pcre2-$PCRE2_VERSION.tar.gz" "pcre2-$PCRE2_VERSION.tar.gz" || return 1
    cd "$BUILD_DIR"; [ ! -d "pcre2-$PCRE2_VERSION" ] && with_system_env tar -xzf "pcre2-$PCRE2_VERSION.tar.gz"
    cd "$BUILD_DIR/pcre2-$PCRE2_VERSION"
    ./configure --prefix="$DEPS_DIR" --libdir="$DEPS_DIR/lib" --enable-jit && \
    make -j"$NPROC" && make install && mark_done "pcre2"
}

build_libxml2() {
    is_done "libxml2" && return 0
    log_info "Building libxml2 $LIBXML2_VERSION..."
    local mm; mm=$(echo "$LIBXML2_VERSION" | cut -d. -f1,2)
    cd "$BUILD_DIR"

    if [ ! -d "libxml2-$LIBXML2_VERSION" ]; then
        safe_download "https://github.com/GNOME/libxml2/archive/refs/tags/v$LIBXML2_VERSION.tar.gz" "libxml2-$LIBXML2_VERSION.tar.gz" 2>/dev/null || \
        safe_download "https://download.gnome.org/sources/libxml2/$mm/libxml2-$LIBXML2_VERSION.tar.xz" "libxml2-$LIBXML2_VERSION.tar.xz" || return 1

        if [ -f "libxml2-$LIBXML2_VERSION.tar.gz" ]; then
            with_system_env tar -xf "libxml2-$LIBXML2_VERSION.tar.gz"
            # GitHub extracts to libxml2-v$VERSION — rename to expected name
            if [ -d "libxml2-v$LIBXML2_VERSION" ] && [ ! -d "libxml2-$LIBXML2_VERSION" ]; then
                mv "libxml2-v$LIBXML2_VERSION" "libxml2-$LIBXML2_VERSION"
            fi
        elif [ -f "libxml2-$LIBXML2_VERSION.tar.xz" ]; then
            with_system_env tar -xJf "libxml2-$LIBXML2_VERSION.tar.xz"
        fi
    fi

    [ ! -d "libxml2-$LIBXML2_VERSION" ] && { log_error "libxml2 source dir missing after extraction"; return 1; }
    cd "$BUILD_DIR/libxml2-$LIBXML2_VERSION"
    [ ! -f configure ] && with_system_env autoreconf -fi
    ./configure --prefix="$DEPS_DIR" --libdir="$DEPS_DIR/lib" --without-python --without-lzma && \
    make -j"$NPROC" && make install && mark_done "libxml2"
}

build_libxslt() {
    is_done "libxslt" && return 0
    log_info "Building libxslt $LIBXSLT_VERSION..."
    local mm; mm=$(echo "$LIBXSLT_VERSION" | cut -d. -f1,2)
    cd "$BUILD_DIR"

    if [ ! -d "libxslt-$LIBXSLT_VERSION" ]; then
        safe_download "https://github.com/GNOME/libxslt/archive/refs/tags/v$LIBXSLT_VERSION.tar.gz" "libxslt-$LIBXSLT_VERSION.tar.gz" 2>/dev/null || \
        safe_download "https://download.gnome.org/sources/libxslt/$mm/libxslt-$LIBXSLT_VERSION.tar.xz" "libxslt-$LIBXSLT_VERSION.tar.xz" || return 1

        if [ -f "libxslt-$LIBXSLT_VERSION.tar.gz" ]; then
            with_system_env tar -xf "libxslt-$LIBXSLT_VERSION.tar.gz"
            # GitHub extracts to libxslt-v$VERSION — rename to expected name
            if [ -d "libxslt-v$LIBXSLT_VERSION" ] && [ ! -d "libxslt-$LIBXSLT_VERSION" ]; then
                mv "libxslt-v$LIBXSLT_VERSION" "libxslt-$LIBXSLT_VERSION"
            fi
        elif [ -f "libxslt-$LIBXSLT_VERSION.tar.xz" ]; then
            with_system_env tar -xJf "libxslt-$LIBXSLT_VERSION.tar.xz"
        fi
    fi

    [ ! -d "libxslt-$LIBXSLT_VERSION" ] && { log_error "libxslt source dir missing after extraction"; return 1; }
    cd "$BUILD_DIR/libxslt-$LIBXSLT_VERSION"
    [ ! -f configure ] && with_system_env autoreconf -fi
    ./configure --prefix="$DEPS_DIR" --libdir="$DEPS_DIR/lib" \
        --with-libxml-prefix="$DEPS_DIR" --without-python --without-crypto && \
    make -j"$NPROC" && make install && mark_done "libxslt"
}

build_curl() {
    is_done "curl" && return 0
    log_info "Building curl $CURL_VERSION..."
    safe_download "https://curl.se/download/curl-$CURL_VERSION.tar.gz" "curl-$CURL_VERSION.tar.gz" || return 1
    cd "$BUILD_DIR"; [ ! -d "curl-$CURL_VERSION" ] && with_system_env tar -xzf "curl-$CURL_VERSION.tar.gz"
    cd "$BUILD_DIR/curl-$CURL_VERSION"
    # Disable every optional feature that could drag in system libraries.
    # The fixup_pkgconfig sanitizer will catch any that leak through anyway,
    # but --without is belt-and-suspenders.
    ./configure --prefix="$DEPS_DIR" --libdir="$DEPS_DIR/lib" \
        --with-openssl="$DEPS_DIR" --with-zlib="$DEPS_DIR" \
        --without-libpsl \
        --without-brotli --without-zstd \
        --without-nghttp2 --without-nghttp3 --without-quiche \
        --without-libidn2 --without-librtmp --without-libssh2 \
        --without-gssapi --without-schannel \
        --disable-ldap --disable-ldaps && \
    make -j"$NPROC" && make install && mark_done "curl"
}

build_oniguruma() {
    is_done "oniguruma" && return 0
    log_info "Building oniguruma $ONIGURUMA_VERSION..."
    safe_download "https://github.com/kkos/oniguruma/releases/download/v$ONIGURUMA_VERSION/onig-$ONIGURUMA_VERSION.tar.gz" "onig-$ONIGURUMA_VERSION.tar.gz" || return 1
    cd "$BUILD_DIR"; [ ! -d "onig-$ONIGURUMA_VERSION" ] && with_system_env tar -xzf "onig-$ONIGURUMA_VERSION.tar.gz"
    cd "$BUILD_DIR/onig-$ONIGURUMA_VERSION"
    ./configure --prefix="$DEPS_DIR" --libdir="$DEPS_DIR/lib" CFLAGS="-O2 -Wno-error" && \
    make -j"$NPROC" && make install && mark_done "oniguruma"
}

build_sqlite() {
    is_done "sqlite" && return 0
    log_info "Building SQLite..."
    # SQLite uses year-based URL paths. Try current year first, then prior year as fallback.
    local cur_year; cur_year=$(date +%Y)
    safe_download "https://www.sqlite.org/${cur_year}/sqlite-autoconf-$SQLITE_VERSION.tar.gz" "sqlite-autoconf-$SQLITE_VERSION.tar.gz" || \
    safe_download "https://www.sqlite.org/$SQLITE_YEAR/sqlite-autoconf-$SQLITE_VERSION.tar.gz" "sqlite-autoconf-$SQLITE_VERSION.tar.gz" || \
    safe_download "https://www.sqlite.org/$((cur_year-1))/sqlite-autoconf-$SQLITE_VERSION.tar.gz" "sqlite-autoconf-$SQLITE_VERSION.tar.gz" || return 1
    cd "$BUILD_DIR"; [ ! -d "sqlite-autoconf-$SQLITE_VERSION" ] && with_system_env tar -xzf "sqlite-autoconf-$SQLITE_VERSION.tar.gz"
    cd "$BUILD_DIR/sqlite-autoconf-$SQLITE_VERSION"
    ./configure --prefix="$DEPS_DIR" --libdir="$DEPS_DIR/lib" && \
    make -j"$NPROC" && make install && mark_done "sqlite"
}

build_libzip() {
    is_done "libzip" && return 0
    log_info "Building libzip $LIBZIP_VERSION..."
    safe_download "https://libzip.org/download/libzip-$LIBZIP_VERSION.tar.gz" "libzip-$LIBZIP_VERSION.tar.gz" || return 1
    cd "$BUILD_DIR"; [ ! -d "libzip-$LIBZIP_VERSION" ] && with_system_env tar -xzf "libzip-$LIBZIP_VERSION.tar.gz"
    cd "$BUILD_DIR/libzip-$LIBZIP_VERSION"
    if [ -x "$DEPS_DIR/bin/cmake" ]; then
        mkdir -p build_cmake && cd build_cmake
        if "$DEPS_DIR/bin/cmake" .. -DCMAKE_INSTALL_PREFIX="$DEPS_DIR" \
            -DCMAKE_INSTALL_LIBDIR="$DEPS_DIR/lib" \
            -DCMAKE_PREFIX_PATH="$DEPS_DIR" -DCMAKE_C_FLAGS="$CPPFLAGS $CFLAGS" \
            -DCMAKE_CXX_FLAGS="$CPPFLAGS $CXXFLAGS" \
            -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS"; then
            make -j"$NPROC" && make install && { mark_done "libzip"; return 0; }
        fi
        cd "$BUILD_DIR/libzip-$LIBZIP_VERSION"; rm -rf build_cmake
    fi
    [ -x ./configure ] && ./configure --prefix="$DEPS_DIR" --libdir="$DEPS_DIR/lib" && \
        make -j"$NPROC" && make install && { mark_done "libzip"; return 0; }
    command -v autoreconf &>/dev/null && with_system_env autoreconf -fi && \
        ./configure --prefix="$DEPS_DIR" --libdir="$DEPS_DIR/lib" && \
        make -j"$NPROC" && make install && { mark_done "libzip"; return 0; }
    log_error "libzip build failed"; return 1
}

build_libpng() {
    is_done "libpng" && return 0
    log_info "Building libpng $LIBPNG_VERSION..."
    safe_download "https://github.com/pnggroup/libpng/archive/refs/tags/v$LIBPNG_VERSION.tar.gz" "libpng-$LIBPNG_VERSION.tar.gz" || \
    safe_download "https://download.sourceforge.net/libpng/libpng-$LIBPNG_VERSION.tar.gz" "libpng-$LIBPNG_VERSION.tar.gz" || return 1
    cd "$BUILD_DIR"; [ ! -d "libpng-$LIBPNG_VERSION" ] && with_system_env tar -xzf "libpng-$LIBPNG_VERSION.tar.gz"
    cd "$BUILD_DIR/libpng-$LIBPNG_VERSION"
    [ ! -f configure ] && with_system_env autoreconf -fi
    ./configure --prefix="$DEPS_DIR" --libdir="$DEPS_DIR/lib" && \
    make -j"$NPROC" && make install && mark_done "libpng"
}

build_libjpeg() {
    is_done "libjpeg" && return 0
    log_info "Building libjpeg-turbo $LIBJPEG_VERSION..."
    safe_download "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$LIBJPEG_VERSION/libjpeg-turbo-$LIBJPEG_VERSION.tar.gz" "libjpeg-turbo-$LIBJPEG_VERSION.tar.gz" || return 1
    cd "$BUILD_DIR"; [ ! -d "libjpeg-turbo-$LIBJPEG_VERSION" ] && with_system_env tar -xzf "libjpeg-turbo-$LIBJPEG_VERSION.tar.gz"
    cd "$BUILD_DIR/libjpeg-turbo-$LIBJPEG_VERSION"
    mkdir -p build_cmake && cd build_cmake
    "$DEPS_DIR/bin/cmake" .. \
        -DCMAKE_INSTALL_PREFIX="$DEPS_DIR" \
        -DCMAKE_INSTALL_LIBDIR="$DEPS_DIR/lib" \
        -DCMAKE_PREFIX_PATH="$DEPS_DIR" \
        -DENABLE_SHARED=ON -DENABLE_STATIC=ON \
        -DWITH_TURBOJPEG=OFF && \
    make -j"$NPROC" && make install && mark_done "libjpeg"
}

build_freetype() {
    is_done "freetype" && return 0
    log_info "Building freetype $FREETYPE_VERSION..."
    # GitHub tag uses dashes: VER-2-14-3
    local ft_tag; ft_tag="VER-$(echo "$FREETYPE_VERSION" | tr '.' '-')"
    safe_download "https://github.com/freetype/freetype/archive/refs/tags/${ft_tag}.tar.gz" "freetype-$FREETYPE_VERSION.tar.gz" || \
    safe_download "https://download.savannah.gnu.org/releases/freetype/freetype-$FREETYPE_VERSION.tar.gz" "freetype-$FREETYPE_VERSION.tar.gz" || return 1
    cd "$BUILD_DIR"
    if [ ! -d "freetype-$FREETYPE_VERSION" ]; then
        with_system_env tar -xzf "freetype-$FREETYPE_VERSION.tar.gz"
        # GitHub archive extracts as freetype-VER-2-14-3 — rename to expected dir
        local extracted_dir; extracted_dir=$(find "$BUILD_DIR" -maxdepth 1 -type d -name "freetype-*" | head -1)
        [ -n "$extracted_dir" ] && [ "$extracted_dir" != "$BUILD_DIR/freetype-$FREETYPE_VERSION" ] && \
            mv "$extracted_dir" "$BUILD_DIR/freetype-$FREETYPE_VERSION"
    fi
    cd "$BUILD_DIR/freetype-$FREETYPE_VERSION"
    [ ! -f configure ] && with_system_env autoreconf -fi
    ./configure --prefix="$DEPS_DIR" --libdir="$DEPS_DIR/lib" --without-harfbuzz --without-brotli && \
    make -j"$NPROC" && make install && mark_done "freetype"
}

build_icu() {
    is_done "icu" && return 0
    log_info "Building ICU $ICU_VERSION (~15-20 min)..."
    # ICU uses dashes in the release tag (release-77-1) and underscores in the
    # tarball filename (icu4c-77_1-sources.tgz) — neither matches the dot-version string.
    local icu_tag; icu_tag="release-$(echo "$ICU_VERSION" | tr '.' '-')"
    local icu_file; icu_file="icu4c-$(echo "$ICU_VERSION" | tr '.' '_')-sources.tgz"
    safe_download \
        "https://github.com/unicode-org/icu/releases/download/${icu_tag}/${icu_file}" \
        "$icu_file" || return 1
    cd "$BUILD_DIR"; [ ! -d "icu" ] && with_system_env tar -xzf "$icu_file"
    cd "$BUILD_DIR/icu/source"
    ./configure --prefix="$DEPS_DIR" --libdir="$DEPS_DIR/lib" && \
    make -j"$NPROC" && make install && mark_done "icu"
}

build_ncurses() {
    is_done "ncurses" && return 0
    log_info "Building ncurses $NCURSES_VERSION..."
    safe_download "https://ftp.gnu.org/gnu/ncurses/ncurses-$NCURSES_VERSION.tar.gz" "ncurses-$NCURSES_VERSION.tar.gz" || return 1
    cd "$BUILD_DIR"; [ ! -d "ncurses-$NCURSES_VERSION" ] && with_system_env tar -xzf "ncurses-$NCURSES_VERSION.tar.gz"
    cd "$BUILD_DIR/ncurses-$NCURSES_VERSION"
    ./configure --prefix="$DEPS_DIR" --libdir="$DEPS_DIR/lib" \
        --without-shared --without-cxx --without-cxx-binding \
        --without-ada --without-debug --enable-widec --with-termlib && \
    make -j"$NPROC" && make install && mark_done "ncurses"
}

build_libaio() {
    is_done "libaio" && return 0
    log_info "Building libaio $LIBAIO_VERSION..."
    safe_download "https://pagure.io/libaio/archive/libaio-$LIBAIO_VERSION/libaio-libaio-$LIBAIO_VERSION.tar.gz" "libaio-libaio-$LIBAIO_VERSION.tar.gz" || \
    safe_download "https://fedorapeople.org/~fweimer/laio/libaio-libaio-$LIBAIO_VERSION.tar.gz" "libaio-libaio-$LIBAIO_VERSION.tar.gz" || return 1
    cd "$BUILD_DIR"; [ ! -d "libaio-libaio-$LIBAIO_VERSION" ] && with_system_env tar -xzf "libaio-libaio-$LIBAIO_VERSION.tar.gz"
    cd "$BUILD_DIR/libaio-libaio-$LIBAIO_VERSION"
    make prefix="$DEPS_DIR" libdir="$DEPS_DIR/lib" -j"$NPROC" && \
    make prefix="$DEPS_DIR" libdir="$DEPS_DIR/lib" install && mark_done "libaio"
}

build_postgresql() {
    is_done "postgresql" && return 0
    log_info "Building PostgreSQL $POSTGRESQL_VERSION..."
    safe_download "https://ftp.postgresql.org/pub/source/v$POSTGRESQL_VERSION/postgresql-$POSTGRESQL_VERSION.tar.gz" "postgresql-$POSTGRESQL_VERSION.tar.gz" || return 1
    cd "$BUILD_DIR"; [ ! -d "postgresql-$POSTGRESQL_VERSION" ] && with_system_env tar -xzf "postgresql-$POSTGRESQL_VERSION.tar.gz"
    cd "$BUILD_DIR/postgresql-$POSTGRESQL_VERSION"
    ./configure --prefix="$INSTALL_DIR/postgresql" --libdir="$INSTALL_DIR/postgresql/lib" \
        --with-openssl --without-readline --without-icu --without-ldap --without-gssapi \
        --without-zstd --without-lz4 --without-libxml && \
    make -j"$NPROC" && make install || { log_error "PostgreSQL build/install failed"; return 1; }

    # ── Verify install produced the critical header ──────────────────────
    if [ ! -f "$INSTALL_DIR/postgresql/include/libpq-fe.h" ]; then
        log_error "PostgreSQL install missing libpq-fe.h — something went wrong"
        return 1
    fi

    # ── Symlink pg_config into $DEPS_DIR/bin ─────────────────────────────
    # PHP's --with-pgsql (without =DIR) searches PATH for pg_config, then
    # uses `pg_config --includedir` and `pg_config --libdir` to find the
    # header and library paths.  Without this symlink, PHP can't find
    # PostgreSQL at all and falls back to a manual search that also fails.
    # Both --with-pgsql and --with-pdo-pgsql need this.
    ln -sf "$INSTALL_DIR/postgresql/bin/pg_config" "$DEPS_DIR/bin/pg_config"

    # ── Symlink shared libs into $DEPS_DIR/lib ───────────────────────────
    # Needed for -L$DEPS_DIR/lib to find them, and for rpath to resolve.
    ln -sf "$INSTALL_DIR/postgresql/lib/libpq.so"* "$DEPS_DIR/lib/" 2>/dev/null || true
    ln -sf "$INSTALL_DIR/postgresql/lib/libpq.a" "$DEPS_DIR/lib/" 2>/dev/null || true
    ln -sf "$INSTALL_DIR/postgresql/lib/libpgcommon.a" "$DEPS_DIR/lib/" 2>/dev/null || true
    ln -sf "$INSTALL_DIR/postgresql/lib/libpgport.a" "$DEPS_DIR/lib/" 2>/dev/null || true

    # ── Copy headers into $DEPS_DIR/include ──────────────────────────────
    # Flat client headers (libpq-fe.h, postgres_ext.h, etc.)
    for header in "$INSTALL_DIR/postgresql/include"/*.h; do
        [ -f "$header" ] && cp -f "$header" "$DEPS_DIR/include/"
    done
    # Server/internal headers under include/postgresql/ subtree
    if [ -d "$INSTALL_DIR/postgresql/include/postgresql" ]; then
        mkdir -p "$DEPS_DIR/include/postgresql"
        cp -rn "$INSTALL_DIR/postgresql/include/postgresql"/* "$DEPS_DIR/include/postgresql/"
    fi

    # ── Copy pkg-config file ─────────────────────────────────────────────
    mkdir -p "$DEPS_DIR/lib/pkgconfig"
    if [ -f "$INSTALL_DIR/postgresql/lib/pkgconfig/libpq.pc" ]; then
        cp "$INSTALL_DIR/postgresql/lib/pkgconfig/libpq.pc" "$DEPS_DIR/lib/pkgconfig/"
    else
        log_warn "libpq.pc not found after PostgreSQL install"
    fi

    # ── Verify the symlink works ─────────────────────────────────────────
    if ! "$DEPS_DIR/bin/pg_config" --includedir &>/dev/null; then
        log_error "pg_config symlink broken"
        return 1
    fi

    mark_done "postgresql"
    log_info "PostgreSQL built successfully (pg_config at $DEPS_DIR/bin/pg_config)"
}

# ── Build all deps ───────────────────────────────────────────────────────────
build_all_deps() {
    is_done "all_deps" && { log_info "All dependencies already built — skipping"; return 0; }
    log_info "Building all dependencies (1-2 hours)..."
    setup_build_flags
    build_cmake       || { log_error "cmake failed";       exit 1; }
    build_zlib        || { log_error "zlib failed";        exit 1; }
    build_sodium      || { log_error "sodium failed";      exit 1; }
    build_openssl     || { log_error "openssl failed";     exit 1; }
    build_pcre2       || { log_error "pcre2 failed";       exit 1; }
    build_libxml2     || { log_error "libxml2 failed";     exit 1; }
    build_libxslt     || { log_error "libxslt failed";     exit 1; }
    build_curl        || { log_error "curl failed";        exit 1; }
    build_oniguruma   || { log_error "oniguruma failed";   exit 1; }
    build_sqlite      || { log_error "sqlite failed";      exit 1; }
    build_libzip      || { log_error "libzip failed";      exit 1; }
    build_libpng      || { log_error "libpng failed";      exit 1; }
    build_libjpeg     || { log_error "libjpeg failed";     exit 1; }
    build_freetype    || { log_error "freetype failed";    exit 1; }
    build_icu         || { log_error "icu failed";         exit 1; }
    build_ncurses     || { log_error "ncurses failed";     exit 1; }
    build_libaio      || { log_error "libaio failed";      exit 1; }
    build_postgresql  || { log_error "postgresql failed";  exit 1; }

    # THE KEY FIX: sanitize ALL .pc files before building PHP
    fixup_pkgconfig

    mark_done "all_deps"
    log_info "All dependencies built and pkg-config sanitized"
}

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 1: SYSTEM INSTALLATION  (/opt/webstack)
# ══════════════════════════════════════════════════════════════════════════════

phase1_ensure_install_dir() {
    local _owner; _owner="$(id -un):$(id -gn)"
    if [ -d "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ]; then
        log_info "Installation directory: $INSTALL_DIR"
        return 0
    fi
    if [ -d "$INSTALL_DIR" ] && [ ! -w "$INSTALL_DIR" ]; then
        log_info "Fixing ownership of $INSTALL_DIR..."
        sudo chown -R "$_owner" "$INSTALL_DIR" || {
            log_error "Cannot chown $INSTALL_DIR"; exit 1
        }
        return 0
    fi
    log_info "Creating $INSTALL_DIR (requires sudo)..."
    if command -v sudo &>/dev/null; then
        sudo mkdir -p "$INSTALL_DIR" && sudo chown "$_owner" "$INSTALL_DIR" || {
            log_error "Failed to create $INSTALL_DIR"; exit 1
        }
    else
        log_error "Cannot create $INSTALL_DIR — sudo not available"; exit 1
    fi
}

phase1_create_dirs() {
    mkdir -p "$INSTALL_DIR"/{deps/{bin,lib,include,share},build,downloads}
    mkdir -p "$INSTALL_DIR"/{nginx,mariadb,postgresql}
    mkdir -p "$INSTALL_DIR"/php
    for ver in "${PHP_VERSIONS[@]}"; do
        mkdir -p "$INSTALL_DIR/php/$(echo "$ver" | cut -d. -f1,2)"/{bin,sbin,etc/conf.d}
    done
}

phase1_build_nginx() {
    is_done "nginx" && return 0
    log_info "Building Nginx $NGINX_VERSION..."
    setup_build_flags
    download_extract "http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz" "nginx-$NGINX_VERSION"
    cd "$BUILD_DIR/nginx-$NGINX_VERSION"
    ./configure \
        --prefix="$INSTALL_DIR/nginx" \
        --sbin-path="$INSTALL_DIR/nginx/nginx" \
        --with-pcre="$BUILD_DIR/pcre2-$PCRE2_VERSION" \
        --with-zlib="$BUILD_DIR/zlib-$ZLIB_VERSION" \
        --with-openssl="$BUILD_DIR/openssl-$OPENSSL_VERSION" \
        --with-http_ssl_module --with-http_v2_module \
        --with-http_realip_module --with-http_addition_module \
        --with-http_sub_module --with-http_dav_module \
        --with-http_flv_module --with-http_mp4_module \
        --with-http_gunzip_module --with-http_gzip_static_module \
        --with-http_random_index_module --with-http_secure_link_module \
        --with-http_stub_status_module --with-http_auth_request_module && \
    make -j"$NPROC" && make install && mark_done "nginx"
}

phase1_build_php() {
    local version=$1
    local major_minor
    major_minor=$(echo "$version" | cut -d. -f1,2)

    is_done "php-$version" && return 0
    [ -f "$INSTALL_DIR/php/$major_minor/bin/php" ] && {
        mark_done "php-$version"; return 0;
    }

    log_info "Building PHP $version..."
    setup_build_flags

    local fn="php-$version.tar.gz"
    safe_download "https://www.php.net/distributions/$fn" "$fn" || return 1

    cd "$BUILD_DIR"
    [ ! -d "php-$version" ] && with_system_env tar -xzf "$fn"
    cd "$BUILD_DIR/php-$version"

    # -----------------------------
    # Deterministic dependency setup
    # -----------------------------

    local CONFIGURE_PGSQL_FLAGS=""
    local PG_CONFIG_BIN=""

    # Try to locate pg_config explicitly (prefer DEPS_DIR)
    if [ -x "$DEPS_DIR/bin/pg_config" ]; then
        PG_CONFIG_BIN="$DEPS_DIR/bin/pg_config"
    elif command -v pg_config >/dev/null 2>&1; then
        PG_CONFIG_BIN="$(command -v pg_config)"
    fi

    if [ -n "$PG_CONFIG_BIN" ]; then
        export PG_CONFIG="$PG_CONFIG_BIN"
        local PG_PREFIX
        PG_PREFIX="$(dirname "$(dirname "$PG_CONFIG_BIN")")"

        CONFIGURE_PGSQL_FLAGS="\
            --with-pgsql=$PG_PREFIX \
            --with-pdo-pgsql=$PG_PREFIX"

        log_info "Using PostgreSQL from: $PG_PREFIX"
    else
        log_info "PostgreSQL not found → disabling pgsql support"
        CONFIGURE_PGSQL_FLAGS="--without-pgsql --without-pdo-pgsql"
    fi

    # -----------------------------
    # Build
    # -----------------------------

    LIBS="-lz -lm" \
    CPPFLAGS="-I$DEPS_DIR/include" \
    LDFLAGS="-L$DEPS_DIR/lib" \
    PKG_CONFIG_PATH="$DEPS_DIR/lib/pkgconfig" \
    ./configure \
        --prefix="$INSTALL_DIR/php/$major_minor" \
        --enable-fpm \
        --with-config-file-path="$INSTALL_DIR/php/$major_minor/etc" \
        --with-config-file-scan-dir="$INSTALL_DIR/php/$major_minor/etc/conf.d" \
        --with-openssl \
        --with-curl \
        --enable-mbstring \
        --with-zip \
        --enable-bcmath \
        --enable-pcntl \
        --enable-ftp \
        --enable-exif \
        --enable-calendar \
        --enable-intl \
        --enable-soap \
        --enable-sockets \
        --with-mysqli \
        --with-pdo-mysql \
        --with-pdo-sqlite \
        $CONFIGURE_PGSQL_FLAGS \
        --with-jpeg="$DEPS_DIR" \
        --with-freetype="$DEPS_DIR" \
        --enable-gd \
        --without-webp \
        --without-avif \
        --without-xpm \
        --with-zlib="$DEPS_DIR" \
        --enable-ctype \
        --with-sodium \
        --with-xsl \
        --enable-xml \
        --enable-opcache \
        --enable-opcache-jit \
        --with-libxml \
        --with-onig \
        --disable-cgi \
        || { log_error "PHP $version configure failed"; return 1; }

    make -j"$NPROC" || { log_error "PHP $version build failed"; return 1; }
    make install    || { log_error "PHP $version install failed"; return 1; }

    # -----------------------------
    # Config setup
    # -----------------------------

    [ -f php.ini-development ] && \
        cp php.ini-development "$INSTALL_DIR/php/$major_minor/etc/php.ini"

    local ext_dir opcache_so
    ext_dir=$("$INSTALL_DIR/php/$major_minor/bin/php-config" --extension-dir 2>/dev/null || true)
    opcache_so="$ext_dir/opcache.so"

    if [ -f "$opcache_so" ]; then
        local tmp_ini
        tmp_ini=$(mktemp)
        {
            echo "[PHP]"
            echo "zend_extension=\"${opcache_so}\""
            echo ""
            grep -v '^\[PHP\]' "$INSTALL_DIR/php/$major_minor/etc/php.ini"
        } > "$tmp_ini"
        mv "$tmp_ini" "$INSTALL_DIR/php/$major_minor/etc/php.ini"
    fi

    cat > "$INSTALL_DIR/php/$major_minor/etc/conf.d/webstack.ini" << 'INI'
memory_limit = 256M
max_input_vars = 5000
max_input_time = 300
post_max_size = 256M
upload_max_filesize = 256M
max_execution_time = 300
default_socket_timeout = 60
error_reporting = E_ALL
display_errors = On
display_startup_errors = On
log_errors = On
session.gc_maxlifetime = 7200
session.cookie_secure = 0
session.cookie_httponly = 1
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 2
opcache.save_comments = 1
opcache.jit = tracing
opcache.jit_buffer_size = 64M
INI

    [ -f "$INSTALL_DIR/php/$major_minor/bin/php" ] && \
        mark_done "php-$version"
}

phase1_build_mariadb() {
    is_done "mariadb" && return 0
    log_info "Building MariaDB $MARIADB_VERSION..."
    setup_build_flags
    download_extract "https://archive.mariadb.org/mariadb-$MARIADB_VERSION/source/mariadb-$MARIADB_VERSION.tar.gz" "mariadb-$MARIADB_VERSION"
    cd "$BUILD_DIR/mariadb-$MARIADB_VERSION"; mkdir -p build && cd build
    "$DEPS_DIR/bin/cmake" .. \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_DIR/mariadb" \
        -DCMAKE_INSTALL_LIBDIR="$INSTALL_DIR/mariadb/lib" \
        -DCMAKE_PREFIX_PATH="$DEPS_DIR" \
        -DWITH_SSL="$DEPS_DIR" -DWITH_ZLIB=bundled \
        -DZLIB_INCLUDE_DIR="$DEPS_DIR/include" -DZLIB_LIBRARY="$DEPS_DIR/lib/libz.so" \
        -DWITH_EMBEDDED_SERVER=OFF -DWITH_UNIT_TESTS=OFF \
        -DWITHOUT_SYSTEMD=ON \
        -DWITH_INNODB_LZ4=OFF -DWITH_INNODB_LZMA=OFF \
        -DWITH_INNODB_SNAPPY=OFF -DWITH_INNODB_BZIP2=OFF \
        -DWITH_LIBEVENT=bundled \
        -DPLUGIN_AUTH_GSSAPI_CLIENT=OFF -DPLUGIN_AUTH_GSSAPI=NO \
        -DPLUGIN_ROCKSDB=NO -DPLUGIN_MROONGA=NO -DPLUGIN_SPIDER=NO \
        -DPLUGIN_OQGRAPH=NO -DPLUGIN_TOKUDB=NO -DPLUGIN_CONNECT=NO \
        -DCMAKE_C_FLAGS="$CPPFLAGS $CFLAGS" -DCMAKE_CXX_FLAGS="$CPPFLAGS $CXXFLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" || {
        log_error "MariaDB cmake failed"; return 1
    }
    make -j"$NPROC" mariadbd mariadb-admin mariadb-dump mariadb-check || \
    { make clean; make -j2 mariadbd mariadb-admin mariadb-dump mariadb-check || \
      { make clean; make -j1 mariadbd mariadb-admin mariadb-dump mariadb-check || \
        { log_error "MariaDB build failed"; return 1; }; }; }
    make install || { log_error "MariaDB install failed"; return 1; }
    mark_done "mariadb"
}

phase1_run() {
    [ -f "$INSTALL_DIR/.compiled" ] && { log_info "Phase 1 already complete — skipping"; return 0; }
    log_step "═══ PHASE 1: System Installation to $INSTALL_DIR ═══"
    phase1_ensure_install_dir
    phase1_create_dirs
    check_and_install_build_tools
    build_all_deps
    phase1_build_nginx
    for ver in "${PHP_VERSIONS[@]}"; do
        phase1_build_php "$ver" || { log_error "PHP $ver failed"; exit 1; }
    done
    phase1_build_mariadb
    touch "$INSTALL_DIR/.compiled"
    log_info "Phase 1 complete: $INSTALL_DIR"
}

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 2: USER SETUP
# ══════════════════════════════════════════════════════════════════════════════

phase2_create_dirs() {
    mkdir -p "$USER_DIR"/{nginx/logs,php,mariadb/{data,logs},postgresql/{data,logs}}
    for ver in "${PHP_VERSIONS[@]}"; do
        mkdir -p "$USER_DIR/php/$(echo "$ver" | cut -d. -f1,2)/logs"
    done
    mkdir -p "$USER_WWW"
}

phase2_nginx_conf() {
    cat > "$USER_DIR/nginx/nginx.conf" << EOF
worker_processes auto;
error_log $USER_DIR/nginx/logs/error.log;
pid $USER_DIR/nginx/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       $INSTALL_DIR/nginx/conf/mime.types;
    default_type  application/octet-stream;
    sendfile on;
    keepalive_timeout 65;

    server {
        listen 8080;
        server_name localhost;
        root $USER_WWW;
        index index.php index.html index.htm;

        location / {
            try_files \$uri \$uri/ /index.php?\$query_string;
        }

        location ~ \\.php\$ {
            fastcgi_pass unix:$USER_DIR/php/current/php-fpm.sock;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
            include $INSTALL_DIR/nginx/conf/fastcgi_params;
        }

        location ~ /\\.ht {
            deny all;
        }
    }
}
EOF
}

phase2_php_fpm_conf() {
    local ver=$1
    cat > "$USER_DIR/php/$ver/php-fpm.conf" << EOF
[global]
pid = $USER_DIR/php/$ver/php-fpm.pid
error_log = $USER_DIR/php/$ver/logs/php-fpm.log

[www]
user = $USER
group = $(id -gn)
listen = $USER_DIR/php/$ver/php-fpm.sock
listen.owner = $USER
listen.group = $(id -gn)
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
EOF
}

phase2_mariadb_conf() {
    cat > "$USER_DIR/mariadb/my.cnf" << EOF
[mysqld]
basedir = $INSTALL_DIR/mariadb
datadir = $USER_DIR/mariadb/data
port = 3306
socket = $USER_DIR/mariadb/mariadb.sock
pid-file = $USER_DIR/mariadb/mariadb.pid
log-error = $USER_DIR/mariadb/logs/error.log
bind-address = 127.0.0.1
skip-name-resolve

[client]
socket = $USER_DIR/mariadb/mariadb.sock
port = 3306
EOF
    chmod 0600 "$USER_DIR/mariadb/my.cnf"
}

phase2_mariadb_init() {
    log_info "Initializing MariaDB database..."
    local init_log="$USER_DIR/mariadb/logs/init.log"
    rm -rf "$USER_DIR/mariadb/data"/*
    do_init() {
        ulimit -n 65536 2>/dev/null || true
        "$INSTALL_DIR/mariadb/scripts/mariadb-install-db" \
            --no-defaults --basedir="$INSTALL_DIR/mariadb" \
            --datadir="$USER_DIR/mariadb/data" --user="$USER" \
            --auth-root-authentication-method=normal \
            --innodb-log-file-size=48M --innodb-buffer-pool-size=64M "$@"
    }
    do_init 2>&1 | tee "$init_log" || {
        log_warn "Retrying with --verbose..."
        rm -rf "$USER_DIR/mariadb/data"/*
        do_init --verbose 2>&1 | tee "$init_log" || {
            log_error "MariaDB init failed — see $init_log"; return 1
        }
    }
    local ROOT_PW="123456" APP_USER="webstack" APP_PW="webstack"
    "$INSTALL_DIR/mariadb/bin/mariadbd" --no-defaults --bootstrap \
        --basedir="$INSTALL_DIR/mariadb" --datadir="$USER_DIR/mariadb/data" \
        --log-error="$USER_DIR/mariadb/logs/auth-setup.log" <<EOF
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED BY '${ROOT_PW}';
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '${ROOT_PW}';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS '${APP_USER}'@'localhost' IDENTIFIED BY '${APP_PW}';
CREATE USER IF NOT EXISTS '${APP_USER}'@'127.0.0.1' IDENTIFIED BY '${APP_PW}';
GRANT ALL PRIVILEGES ON *.* TO '${APP_USER}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${APP_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
}

phase2_postgresql_init() {
    log_info "Initializing PostgreSQL database..."
    local PGDATA="$USER_DIR/postgresql/data"
    local PGLOG="$USER_DIR/postgresql/logs"
    local PG_BIN="$INSTALL_DIR/postgresql/bin"
    local PG_PW="123456"
    rm -rf "$PGDATA"/*
    local pwfile; pwfile=$(mktemp); echo "$PG_PW" > "$pwfile"
    "$PG_BIN/initdb" -D "$PGDATA" -U postgres --pwfile="$pwfile" \
        --auth=md5 --auth-local=trust --encoding=UTF8 --locale=C --no-instructions || {
        rm -f "$pwfile"; log_error "PostgreSQL initdb failed"; return 1
    }
    rm -f "$pwfile"
    cat >> "$PGDATA/pg_hba.conf" << 'HBA'
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
HBA
    "$PG_BIN/pg_ctl" -D "$PGDATA" -l "$PGLOG/postgresql.log" start -w || {
        log_error "PostgreSQL failed to start"; return 1
    }
    "$PG_BIN/createdb" -U postgres webstack 2>/dev/null || true
    "$PG_BIN/pg_ctl" -D "$PGDATA" stop -w || true
}

phase2_test_page() {
    cat > "$USER_WWW/index.php" << 'EOF'
<?php
if (isset($_GET['info'])) { phpinfo(); exit; }
?>
<!DOCTYPE html>
<html><head><title>Web Stack</title>
<style>
body{font-family:Arial,sans-serif;margin:40px;background:#f5f5f5}
.c{background:#fff;padding:30px;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,.1)}
h1{color:#333}.i{background:#e8f5e9;padding:15px;border-radius:4px;margin:20px 0}
table{width:100%;border-collapse:collapse;margin:20px 0}
th,td{padding:12px;text-align:left;border-bottom:1px solid #ddd}th{background:#f5f5f5}
.btn{display:inline-block;padding:10px 16px;background:#2563eb;color:#fff;
     text-decoration:none;border-radius:6px;font-weight:500}
.btn:hover{background:#1d4ed8}
</style></head><body><div class="c">
<h1>🚀 Web Stack is Running!</h1>
<div class="i">
<strong>PHP:</strong> <a href="/index.php?info=1"><?php echo phpversion(); ?></a><br>
<strong>Server:</strong> <?php echo $_SERVER['SERVER_SOFTWARE']; ?><br>
<strong>Root:</strong> <?php echo $_SERVER['DOCUMENT_ROOT']; ?>
</div>
<h2>Extensions</h2><table>
<?php
 $ext = get_loaded_extensions(); sort($ext);
foreach (array_chunk($ext, 3) as $chunk) {
    echo "<tr>"; foreach ($chunk as $e) echo "<td>$e</td>"; echo "</tr>";
}
?></table>
</div>
<p><a href="/index.php?info=1" class="btn">PHP INFO</a></p>
</body></html>
EOF
}

phase2_management_scripts() {
    local bindir="$USER_DIR/bin"
    mkdir -p "$bindir"

    cat > "$bindir/start.sh" << 'START_EOF'
#!/bin/bash
INST="$(dirname "$(readlink -f "$0")")/.."
[ -f "$INST/.paths" ] && . "$INST/.paths"
[ -z "$INSTALL_DIR" ] && { echo "Cannot find install path"; exit 1; }
echo "Starting Web Stack..."
if [ ! -f "$USER_DIR/postgresql/data/postmaster.pid" ]; then
    "$INSTALL_DIR/postgresql/bin/pg_ctl" -D "$USER_DIR/postgresql/data" \
        -l "$USER_DIR/postgresql/logs/postgresql.log" start
    echo "  PostgreSQL started"
else echo "  PostgreSQL already running"; fi
if [ ! -f "$USER_DIR/mariadb/mariadb.pid" ]; then
    "$INSTALL_DIR/mariadb/bin/mariadbd-safe" --defaults-file="$USER_DIR/mariadb/my.cnf" &
    sleep 2; echo "  MariaDB started"
else echo "  MariaDB already running"; fi
if [ -L "$USER_DIR/php/current" ]; then
    CUR=$(basename "$(readlink "$USER_DIR/php/current")")
    if [ ! -f "$USER_DIR/php/current/php-fpm.pid" ]; then
        "$INSTALL_DIR/php/$CUR/sbin/php-fpm" -y "$USER_DIR/php/$CUR/php-fpm.conf" && \
            echo "  PHP-FPM $CUR started" || echo "  PHP-FPM $CUR FAILED — check $USER_DIR/php/$CUR/logs/php-fpm.log"
    else echo "  PHP-FPM already running"; fi
else echo "  No PHP version selected (run: webstack-php <version>)"; fi
if [ ! -f "$USER_DIR/nginx/nginx.pid" ]; then
    "$INSTALL_DIR/nginx/nginx" -c "$USER_DIR/nginx/nginx.conf"
    echo "  Nginx started → http://localhost:8080"
else echo "  Nginx already running"; fi
echo "Done!"
START_EOF

    cat > "$bindir/stop.sh" << 'STOP_EOF'
#!/bin/bash
INST="$(dirname "$(readlink -f "$0")")/.."
[ -f "$INST/.paths" ] && . "$INST/.paths"
[ -z "$INSTALL_DIR" ] && { echo "Cannot find install path"; exit 1; }
echo "Stopping Web Stack..."
[ -f "$USER_DIR/nginx/nginx.pid" ] && { kill "$(cat "$USER_DIR/nginx/nginx.pid")" 2>/dev/null; echo "  Nginx stopped"; }
if [ -L "$USER_DIR/php/current" ] && [ -f "$USER_DIR/php/current/php-fpm.pid" ]; then
    kill "$(cat "$USER_DIR/php/current/php-fpm.pid")" 2>/dev/null; echo "  PHP-FPM stopped"; fi
[ -f "$USER_DIR/mariadb/mariadb.pid" ] && {
    "$INSTALL_DIR/mariadb/bin/mariadb-admin" --defaults-file="$USER_DIR/mariadb/my.cnf" shutdown 2>/dev/null || \
    kill "$(cat "$USER_DIR/mariadb/mariadb.pid")" 2>/dev/null; echo "  MariaDB stopped"; }
[ -f "$USER_DIR/postgresql/data/postmaster.pid" ] && {
    "$INSTALL_DIR/postgresql/bin/pg_ctl" -D "$USER_DIR/postgresql/data" stop -m fast; echo "  PostgreSQL stopped"; }
echo "Done!"
STOP_EOF

    cat > "$bindir/switch-php.sh" << 'SWITCH_EOF'
#!/bin/bash
INST="$(dirname "$(readlink -f "$0")")/.."
[ -f "$INST/.paths" ] && . "$INST/.paths"
[ -z "$INSTALL_DIR" ] && { echo "Cannot find install path"; exit 1; }
VER=$1
if [ -z "$VER" ]; then
    echo "Usage: webstack-php <version>"
    echo "Available: $(ls "$INSTALL_DIR/php" | grep -E '^[0-9]+\.[0-9]+$' | tr '\n' ' ')"
    exit 1
fi
[ ! -d "$INSTALL_DIR/php/$VER" ] && { echo "PHP $VER not installed"; exit 1; }
[ -f "$USER_DIR/php/current/php-fpm.pid" ] && kill "$(cat "$USER_DIR/php/current/php-fpm.pid")" 2>/dev/null; sleep 1
rm -f "$USER_DIR/php/current"
ln -s "$USER_DIR/php/$VER" "$USER_DIR/php/current"
"$INSTALL_DIR/php/$VER/sbin/php-fpm" -y "$USER_DIR/php/$VER/php-fpm.conf"
echo "Switched to PHP $VER"
SWITCH_EOF

    cat > "$bindir/mysql.sh" << 'MYSQL_EOF'
#!/bin/bash
INST="$(dirname "$(readlink -f "$0")")/.."
[ -f "$INST/.paths" ] && . "$INST/.paths"
exec "$INSTALL_DIR/mariadb/bin/mysql" --defaults-file="$USER_DIR/mariadb/my.cnf" "$@"
MYSQL_EOF

    cat > "$bindir/psql.sh" << 'PSQL_EOF'
#!/bin/bash
INST="$(dirname "$(readlink -f "$0")")/.."
[ -f "$INST/.paths" ] && . "$INST/.paths"
if [[ "$*" != *"-U"* && "$*" != *"--username"* ]]; then
    exec "$INSTALL_DIR/postgresql/bin/psql" -U postgres "$@"
else
    exec "$INSTALL_DIR/postgresql/bin/psql" "$@"
fi
PSQL_EOF

    cat > "$bindir/php.sh" << 'PHPCLI_EOF'
#!/bin/bash
INST="$(dirname "$(readlink -f "$0")")/.."
[ -f "$INST/.paths" ] && . "$INST/.paths"
if [ -L "$USER_DIR/php/current" ]; then
    CUR=$(basename "$(readlink "$USER_DIR/php/current")")
    exec "$INSTALL_DIR/php/$CUR/bin/php" "$@"
else echo "No PHP version selected. Run: webstack-php <version>"; exit 1; fi
PHPCLI_EOF

    cat > "$bindir/composer.sh" << 'COMP_EOF'
#!/bin/bash
INST="$(dirname "$(readlink -f "$0")")/.."
[ -f "$INST/.paths" ] && . "$INST/.paths"
COMPOSER_BIN="$USER_DIR/bin/composer.phar"
if [ ! -f "$COMPOSER_BIN" ]; then
    EXPECTED_CHECKSUM="$(wget -qO- https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', '$COMPOSER_BIN.installer');"
    php "$COMPOSER_BIN.installer" --install-dir="$USER_DIR/bin" --filename=composer.phar
    rm -f "$COMPOSER_BIN.installer"
fi
if [ -L "$USER_DIR/php/current" ]; then
    CUR=$(basename "$(readlink "$USER_DIR/php/current")")
    exec "$INSTALL_DIR/php/$CUR/bin/php" "$COMPOSER_BIN" "$@"
else echo "No PHP version selected. Run: webstack-php <version>"; exit 1; fi
COMP_EOF

    chmod +x "$bindir"/*.sh

    cat > "$USER_DIR/.paths" << PATHS_EOF
INSTALL_DIR="$INSTALL_DIR"
USER_DIR="$USER_DIR"
USER_WWW="$USER_WWW"
PATHS_EOF

    mkdir -p "$HOME/.local/bin"
    ln -sf "$bindir/start.sh"      "$HOME/.local/bin/webstack-start"
    ln -sf "$bindir/stop.sh"       "$HOME/.local/bin/webstack-stop"
    ln -sf "$bindir/switch-php.sh" "$HOME/.local/bin/webstack-php"
    ln -sf "$bindir/mysql.sh"      "$HOME/.local/bin/webstack-mysql"
    ln -sf "$bindir/psql.sh"       "$HOME/.local/bin/webstack-psql"
    ln -sf "$bindir/php.sh"        "$HOME/.local/bin/webstack-php-cli"
    ln -sf "$bindir/composer.sh"   "$HOME/.local/bin/webstack-composer"
}

phase2_run() {
    [ -f "$USER_DIR/.setup" ] && { log_info "Phase 2 already complete — skipping"; return 0; }
    if [ "$EUID" -eq 0 ]; then
        log_error "Phase 2 must run as your user, not root!"
        exit 1
    fi
    log_step "═══ PHASE 2: User Setup ($USER) ═══"
    phase2_create_dirs
    phase2_nginx_conf
    for ver in "${PHP_VERSIONS[@]}"; do
        local mm; mm=$(echo "$ver" | cut -d. -f1,2)
        phase2_php_fpm_conf "$mm"
    done
    local default_php; default_php=$(echo "${PHP_VERSIONS[0]}" | cut -d. -f1,2)
    rm -f "$USER_DIR/php/current"
    ln -s "$USER_DIR/php/$default_php" "$USER_DIR/php/current"
    log_info "Default PHP: $default_php"
    phase2_mariadb_conf
    phase2_mariadb_init
    phase2_postgresql_init
    phase2_test_page
    phase2_management_scripts
    touch "$USER_DIR/.setup"
    log_info "Phase 2 complete"
}

# ══════════════════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════════════════

main() {
    # ── Non-interactive: CI build mode ────────────────────────────────
    if [ "$BUILD_ONLY" -eq 1 ]; then
        log_step "═══ PHASE 1: Build Only (CI mode) ═══"
        phase1_run
        echo ""
        log_info "Build complete. /opt/webstack is ready for packaging."
        return
    fi

    # ── Non-interactive: .run installer mode ──────────────────────────
    if [ "$PHASE2_ONLY" -eq 1 ]; then
        log_step "═══ PHASE 2: User Setup (pre-compiled release) ═══"
        phase2_run

        echo ""
        echo "═══════════════════════════════════════════════════════════"
        log_info "Installation complete!"
        echo ""
        echo "  Compiled stack:  $INSTALL_DIR/"
        echo "  Your data:       $USER_DIR/"
        echo "  Your web root:   $USER_WWW/"
        echo ""
        echo "  GUI:"
        echo "    webstack-manager      Open control panel"
        echo "    (also in your application menu as 'WebStack Manager')"
        echo ""
        echo "  CLI:"
        echo "    webstack-start        Start all services"
        echo "    webstack-stop         Stop all services"
        echo "    webstack-php 8.4      Switch PHP version"
        echo "    webstack-mysql        MariaDB client"
        echo "    webstack-psql         PostgreSQL client"
        echo "    webstack-php-cli      PHP CLI (active version)"
        echo "    webstack-composer     Composer (auto-installs)"
        echo ""
        echo "  Credentials:"
        echo "    MariaDB root:      123456"
        echo "    MariaDB app user:  webstack / webstack"
        echo "    PostgreSQL:        postgres / 123456"
        echo ""
        echo "  URL: http://localhost:8080"
        echo ""
        echo '  echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.bashrc'
        echo "    source ~/.bashrc"
        echo ""
        echo "  To start: webstack-start"
        echo "═══════════════════════════════════════════════════════════"
        return
    fi

    # ── Interactive mode (original behavior, unchanged) ───────────────
    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║     Linux Universal Isolated Web Stack Installer         ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║                                                          ║"
    echo "║  Binaries:   /opt/webstack        (fixed, shared)       ║"
    echo "║  Your data:  ~/.webstack/          (per-user)           ║"
    echo "║  Your code:  ~/webstack-www/       (per-user)           ║"
    echo "║                                                          ║"
    echo "║  Distro:     $DISTRO_ID                                    "
    echo "║  CPU cores:  $NPROC                                       "
    echo "║  PHP:        ${PHP_VERSIONS[*]}         "
    echo "║  Nginx:      $NGINX_VERSION                                    "
    echo "║  MariaDB:    $MARIADB_VERSION                                  "
    echo "║  PostgreSQL: $POSTGRESQL_VERSION                                 "
    echo "║                                                          ║"
    echo "║  ⚠  DO NOT run with sudo — sudo is used internally      ║"
    echo "║                                                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo ""

    # Safety: non-interactive / CI environments have no TTY — default to yes
    if [ -t 0 ]; then
        read -p "Continue? (y/n) " -n 1 -r
        echo
        [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
    else
        echo "[INFO] Non-interactive mode detected — continuing automatically."
    fi

    phase1_run
    phase2_run

    echo ""
    echo "═══════════════════════════════════════════════════════════"
    log_info "Installation complete!"
    echo ""
    echo "  Compiled stack:  $INSTALL_DIR/"
    echo "  Your data:       $USER_DIR/"
    echo "  Your web root:   $USER_WWW/"
    echo ""
    echo "  GUI:"
    echo "    webstack-manager      Open control panel"
    echo "    (also in your application menu as 'WebStack Manager')"
    echo ""
    echo "  CLI:"
    echo "    webstack-start        Start all services"
    echo "    webstack-stop         Stop all services"
    echo "    webstack-php 8.4      Switch PHP version"
    echo "    webstack-mysql        MariaDB client"
    echo "    webstack-psql         PostgreSQL client"
    echo "    webstack-php-cli      PHP CLI (active version)"
    echo "    webstack-composer     Composer (auto-installs)"
    echo ""
    echo "  Credentials:"
    echo "    MariaDB root:      123456"
    echo "    MariaDB app user:  webstack / webstack"
    echo "    PostgreSQL:        postgres / 123456"
    echo ""
    echo "  URL: http://localhost:8080"
    echo ""
    echo '  echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.bashrc'
    echo "    source ~/.bashrc"
    echo ""
    echo "  To start: webstack-start"
    echo ""
    echo "  Free ~3GB after install:"
    echo "    rm -rf $INSTALL_DIR/build $INSTALL_DIR/downloads"
    echo ""
    echo "  Move to another machine:"
    echo "    1. Copy /opt/webstack → new /opt/webstack"
    echo "    2. Re-run this script (Phase 1 skips, Phase 2 runs)"
    echo "═══════════════════════════════════════════════════════════"
}

main
