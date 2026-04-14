#!/bin/bash

# Fully Portable Web Development Stack Installer for Arch Linux
# No system dependencies - everything compiled and isolated

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
STACK_DIR="$HOME/webstack"
BUILD_DIR="$STACK_DIR/build"
DEPS_DIR="$STACK_DIR/deps"
DOWNLOAD_DIR="$STACK_DIR/downloads"

# Version configurations - "8.4.13" "8.3.26" "8.2.28" "8.1.32"
PHP_VERSIONS=("8.4.20" "8.3.30" "8.2.30")
NGINX_VERSION="1.28.3"
MARIADB_VERSION="11.8.6"

# Dependency versions (will be compiled)
OPENSSL_VERSION="3.1.4"
PCRE2_VERSION="10.42"
ZLIB_VERSION="1.3"
LIBXML2_VERSION="2.11.5"
CURL_VERSION="8.19.0"
ONIGURUMA_VERSION="6.9.10"
SQLITE_VERSION="3440000"  # 3.44.0
LIBZIP_VERSION="1.10.1"
LIBPNG_VERSION="1.6.40"
LIBJPEG_VERSION="9e"
FREETYPE_VERSION="2.13.2"
ICU_VERSION="78.1"
NCURSES_VERSION="6.4"
LIBAIO_VERSION="0.3.113"
CMAKE_VERSION="3.27.7"
POSTGRESQL_VERSION="17.9"
SODIUM_VERSION="1.0.22"
LIBXSLT_VERSION="1.1.39"

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Set build flags that point to our deps WITHOUT leaking LD_LIBRARY_PATH.
# Using -rpath bakes the library search path into each compiled binary so
# it finds our libs at runtime without needing LD_LIBRARY_PATH at all.
setup_build_flags() {
    export PKG_CONFIG_PATH="$DEPS_DIR/lib/pkgconfig:$DEPS_DIR/share/pkgconfig"
    export PATH="$DEPS_DIR/bin:$PATH"
    export CPPFLAGS="-I$DEPS_DIR/include"
    # --as-needed: only link libraries actually referenced directly.
    # This stops transitive pulls like libfreetype->libfontconfig->libglib
    # ->pcre2, which drags in system glib and conflicts with our PCRE2.
    export LDFLAGS="-L$DEPS_DIR/lib -Wl,-rpath,$DEPS_DIR/lib -Wl,--as-needed"
    export CFLAGS="-O2"
    export CXXFLAGS="-O2"
    # Explicitly unset LD_LIBRARY_PATH so the system linker never accidentally
    # resolves system library dependencies (e.g. glib -> pcre2) against our
    # private copies.
    unset LD_LIBRARY_PATH
}

# Temporarily clear our custom flags when invoking tools that must link
# purely against system libraries (e.g. download helpers).
with_system_env() {
    local OLD_CPPFLAGS="$CPPFLAGS"
    local OLD_LDFLAGS="$LDFLAGS"
    local OLD_PKG_CONFIG_PATH="$PKG_CONFIG_PATH"
    unset CPPFLAGS LDFLAGS
    export PKG_CONFIG_PATH=""
    "$@"
    local ret=$?
    export CPPFLAGS="$OLD_CPPFLAGS"
    export LDFLAGS="$OLD_LDFLAGS"
    export PKG_CONFIG_PATH="$OLD_PKG_CONFIG_PATH"
    return $ret
}

# Check if running as root
if [ "$EUID" -eq 0 ]; then
    log_error "Please do not run as root"
    exit 1
fi

# Check for basic build tools (gcc, make) - these are essential
check_minimal_tools() {
    log_info "Checking for minimal build tools..."

    if ! command -v gcc &> /dev/null; then
        log_error "gcc not found. You need a basic compiler:"
        echo "  sudo pacman -S gcc make"
        exit 1
    fi

    if ! command -v make &> /dev/null; then
        log_error "make not found. You need make:"
        echo "  sudo pacman -S make"
        exit 1
    fi

    log_info "Minimal tools found"
}

# Create directory structure
setup_directories() {
    log_info "Setting up directory structure..."
    mkdir -p "$STACK_DIR"/{php,nginx,mariadb,www,logs,tmp,bin}
    mkdir -p "$BUILD_DIR"
    mkdir -p "$DEPS_DIR"/{bin,lib,include,share}
    mkdir -p "$DOWNLOAD_DIR"
    mkdir -p "$STACK_DIR"/nginx/{conf,logs}
    mkdir -p "$STACK_DIR"/mariadb/{data,logs,tmp}

    for ver in "${PHP_VERSIONS[@]}"; do
        mkdir -p "$STACK_DIR/php/$ver"/{etc,logs}
    done

    log_info "Downloads directory: $DOWNLOAD_DIR"
    log_info "You can manually place problematic files here before running the script"
}

# Build tracking
BUILD_STATUS_FILE="$STACK_DIR/.build_status"

# Mark a step as completed
mark_completed() {
    local step=$1
    mkdir -p "$(dirname "$BUILD_STATUS_FILE")"
    touch "$BUILD_STATUS_FILE"
    if ! grep -q "^$step$" "$BUILD_STATUS_FILE" 2>/dev/null; then
        echo "$step" >> "$BUILD_STATUS_FILE"
    fi
}

# Check if a step is completed
is_completed() {
    local step=$1
    [ -f "$BUILD_STATUS_FILE" ] && grep -q "^$step$" "$BUILD_STATUS_FILE"
}

# Reset build status (if needed)
reset_build() {
    local step=$1
    if [ -f "$BUILD_STATUS_FILE" ] && [ -n "$step" ]; then
        sed -i "/^$step$/d" "$BUILD_STATUS_FILE"
    elif [ -z "$step" ]; then
        rm -f "$BUILD_STATUS_FILE"
    fi
}

# Download and extract source
download_extract() {
    local url=$1
    local filename=$(basename "$url")
    local extract_dir=$2

    cd "$BUILD_DIR"

    if [ ! -f "$filename" ]; then
        log_info "Downloading $filename..."
        wget -q --show-progress "$url" || {
            log_error "Failed to download $filename from $url"
            return 1
        }
    fi

    if [ ! -d "$extract_dir" ]; then
        log_info "Extracting $filename..."
        if [[ $filename == *.tar.gz ]] || [[ $filename == *.tgz ]]; then
            tar -xzf "$filename" || {
                log_error "Failed to extract $filename"
                return 1
            }
        elif [[ $filename == *.tar.xz ]]; then
            tar -xJf "$filename" || {
                log_error "Failed to extract $filename"
                return 1
            }
        elif [[ $filename == *.tar.bz2 ]]; then
            tar -xjf "$filename" || {
                log_error "Failed to extract $filename"
                return 1
            }
        fi
    fi
}

# Download file with fallbacks
safe_download() {
    local url=$1
    local filename=$2

    # Check if file exists in downloads directory first
    if [ -f "$DOWNLOAD_DIR/$filename" ]; then
        log_info "Found $filename in downloads directory"
        cp "$DOWNLOAD_DIR/$filename" "$BUILD_DIR/$filename"
        return 0
    fi

    # Check if already downloaded in build directory
    if [ -f "$BUILD_DIR/$filename" ]; then
        log_info "File $filename already exists"
        return 0
    fi

    cd "$BUILD_DIR"
    log_info "Downloading $filename..."

    # Temporarily clear custom flags so system wget/curl link against system libs only
    local OLD_LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
    local OLD_LDFLAGS="$LDFLAGS"
    local OLD_CPPFLAGS="$CPPFLAGS"
    unset LD_LIBRARY_PATH LDFLAGS CPPFLAGS

    # Try multiple download methods
    wget -q --show-progress "$url" || \
    curl -L -o "$filename" "$url" || \
    /usr/bin/wget -q --show-progress "$url" || \
    /usr/bin/curl -L -o "$filename" "$url" || {
        export LD_LIBRARY_PATH="$OLD_LD_LIBRARY_PATH"
        log_error "Failed to download $filename from $url"
        log_warn "You can manually download this file and place it in: $DOWNLOAD_DIR"
        return 1
    }

    export LD_LIBRARY_PATH="$OLD_LD_LIBRARY_PATH"
    export LDFLAGS="$OLD_LDFLAGS"
    export CPPFLAGS="$OLD_CPPFLAGS"

    # Copy to downloads directory for future use
    cp "$BUILD_DIR/$filename" "$DOWNLOAD_DIR/$filename" 2>/dev/null || true

    return 0
}

# Download pre-built CMake binary
build_cmake() {
    if is_completed "cmake"; then
        log_info "CMake already built - skipping"
        return 0
    fi
    log_info "Installing CMake $CMAKE_VERSION..."

    local filename="cmake-$CMAKE_VERSION-linux-x86_64.tar.gz"

    safe_download \
        "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "cmake-$CMAKE_VERSION-linux-x86_64" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract CMake"
            return 1
        }
    fi

    # Copy to deps directory
    cp -r "cmake-$CMAKE_VERSION-linux-x86_64"/* "$DEPS_DIR/"

    export PATH="$DEPS_DIR/bin:$PATH"

    mark_completed "cmake"
    log_info "CMake installed successfully"
}

# Build OpenSSL
build_openssl() {
    if is_completed "openssl"; then
        log_info "OpenSSL already built - skipping"
        return 0
    fi

    log_info "Building OpenSSL $OPENSSL_VERSION..."

    local filename="openssl-$OPENSSL_VERSION.tar.gz"

    safe_download \
        "https://www.openssl.org/source/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "openssl-$OPENSSL_VERSION" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract OpenSSL"
            return 1
        }
    fi

    cd "$BUILD_DIR/openssl-$OPENSSL_VERSION"

    ./config --prefix="$DEPS_DIR" --openssldir="$DEPS_DIR/ssl" shared zlib
    make -j$(nproc) || {
        log_error "OpenSSL build failed"
        return 1
    }
    make install_sw || {
        log_error "OpenSSL install failed"
        return 1
    }

    mark_completed "openssl"

    log_info "OpenSSL built successfully"
}

# Build PCRE2
build_pcre2() {
    if is_completed "pcre2"; then
        log_info "PCRE2 already built - skipping"
        return 0
    fi
    log_info "Building PCRE2 $PCRE2_VERSION..."

    local filename="pcre2-$PCRE2_VERSION.tar.gz"

    safe_download \
        "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$PCRE2_VERSION/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "pcre2-$PCRE2_VERSION" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract PCRE2"
            return 1
        }
    fi

    cd "$BUILD_DIR/pcre2-$PCRE2_VERSION"

    ./configure --prefix="$DEPS_DIR" --enable-jit || {
        log_error "PCRE2 configure failed"
        return 1
    }
    make -j$(nproc) || {
        log_error "PCRE2 build failed"
        return 1
    }
    make install || {
        log_error "PCRE2 install failed"
        return 1
    }

    mark_completed "pcre2"

    log_info "PCRE2 built successfully"
}

# Build zlib
build_zlib() {
    if is_completed "zlib"; then
        log_info "zlib already built - skipping"
        return 0
    fi
    log_info "Building zlib $ZLIB_VERSION..."

    local filename="zlib-$ZLIB_VERSION.tar.gz"

    # Try multiple mirrors
    safe_download \
        "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/$filename" \
        "$filename" || \
    safe_download \
        "https://www.zlib.net/$filename" \
        "$filename" || \
    safe_download \
        "https://sourceforge.net/projects/libpng/files/zlib/$ZLIB_VERSION/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "zlib-$ZLIB_VERSION" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract zlib"
            return 1
        }
    fi

    cd "$BUILD_DIR/zlib-$ZLIB_VERSION"

    ./configure --prefix="$DEPS_DIR" || {
        log_error "zlib configure failed"
        return 1
    }
    make -j$(nproc) || {
        log_error "zlib build failed"
        return 1
    }
    make install || {
        log_error "zlib install failed"
        return 1
    }

    mark_completed "zlib"

    log_info "zlib built successfully"
}

# Build libxml2
build_libxml2() {
    if is_completed "libxml2"; then
        log_info "libxml2 already built - skipping"
        return 0
    fi

    log_info "Building libxml2 $LIBXML2_VERSION..."

    local filename="libxml2-$LIBXML2_VERSION.tar.xz"

    safe_download \
        "https://download.gnome.org/sources/libxml2/2.11/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "libxml2-$LIBXML2_VERSION" ]; then
        tar -xJf "$filename" || {
            log_error "Failed to extract libxml2"
            return 1
        }
    fi

    cd "$BUILD_DIR/libxml2-$LIBXML2_VERSION"

    ./configure --prefix="$DEPS_DIR" --without-python || {
        log_error "libxml2 configure failed"
        return 1
    }
    make -j$(nproc) || {
        log_error "libxml2 build failed"
        return 1
    }
    make install || {
        log_error "libxml2 install failed"
        return 1
    }

    mark_completed "libxml2"

    log_info "libxml2 built successfully"
}

# Build curl
build_curl() {
    if is_completed "curl"; then
        log_info "curl already built - skipping"
        return 0
    fi

    log_info "Building curl $CURL_VERSION..."

    local filename="curl-$CURL_VERSION.tar.gz"

    safe_download \
        "https://curl.se/download/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "curl-$CURL_VERSION" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract curl"
            return 1
        }
    fi

    cd "$BUILD_DIR/curl-$CURL_VERSION"

    # --without-libpsl: libpsl (Public Suffix List) is auto-detected from the
    # system on Ubuntu runners and then fails because it's not in our $DEPS_DIR.
    # We don't need it — it's only used by curl's cookie engine for domain
    # isolation, not by PHP's curl extension.
    # --without-brotli, --without-zstd: same problem — system libs detected,
    # not in our build. PHP doesn't need these transfer encodings via libcurl.
    # --without-nghttp2: avoids detecting system nghttp2 which we didn't compile.
    # --disable-ldap: never needed, avoids system libldap detection.
    ./configure --prefix="$DEPS_DIR" \
        --with-openssl="$DEPS_DIR" \
        --with-zlib="$DEPS_DIR" \
        --without-libpsl \
        --without-brotli \
        --without-zstd \
        --without-nghttp2 \
        --disable-ldap \
        --disable-ldaps || {
        log_error "curl configure failed"
        return 1
    }
    make -j$(nproc) || {
        log_error "curl build failed"
        return 1
    }
    make install || {
        log_error "curl install failed"
        return 1
    }

    mark_completed "curl"

    log_info "curl built successfully"
}

# Build oniguruma
build_oniguruma() {
    if is_completed "oniguruma"; then
        log_info "oniguruma already built - skipping"
        return 0
    fi

    log_info "Building oniguruma $ONIGURUMA_VERSION..."

    local filename="onig-$ONIGURUMA_VERSION.tar.gz"

    safe_download \
        "https://github.com/kkos/oniguruma/releases/download/v$ONIGURUMA_VERSION/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "onig-$ONIGURUMA_VERSION" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract oniguruma"
            return 1
        }
    fi

    cd "$BUILD_DIR/onig-$ONIGURUMA_VERSION"

    ./configure --prefix="$DEPS_DIR" CFLAGS="-O2 -Wno-error" || {
        log_error "oniguruma configure failed"
        return 1
    }
    make -j$(nproc) || {
        log_error "oniguruma build failed"
        return 1
    }
    make install || {
        log_error "oniguruma install failed"
        return 1
    }

    mark_completed "oniguruma"

    log_info "oniguruma built successfully"
}

# Build SQLite
build_sqlite() {
    if is_completed "sqlite"; then
        log_info "SQLite already built - skipping"
        return 0
    fi

    log_info "Building SQLite..."

    local filename="sqlite-autoconf-$SQLITE_VERSION.tar.gz"

    safe_download \
        "https://www.sqlite.org/2023/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "sqlite-autoconf-$SQLITE_VERSION" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract SQLite"
            return 1
        }
    fi

    cd "$BUILD_DIR/sqlite-autoconf-$SQLITE_VERSION"

    ./configure --prefix="$DEPS_DIR" || {
        log_error "SQLite configure failed"
        return 1
    }
    make -j$(nproc) || {
        log_error "SQLite build failed"
        return 1
    }
    make install || {
        log_error "SQLite install failed"
        return 1
    }

    mark_completed "sqlite"

    log_info "SQLite built successfully"
}

# Build libzip
build_libzip() {
    if is_completed "libzip"; then
        log_info "libzip already built - skipping"
        return 0
    fi

    log_info "Building libzip $LIBZIP_VERSION..."

    local filename="libzip-$LIBZIP_VERSION.tar.gz"

    safe_download \
        "https://libzip.org/download/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "libzip-$LIBZIP_VERSION" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract libzip"
            return 1
        }
    fi

    cd "$BUILD_DIR/libzip-$LIBZIP_VERSION"
    mkdir -p build && cd build

    "$DEPS_DIR/bin/cmake" .. \
        -DCMAKE_INSTALL_PREFIX="$DEPS_DIR" \
        -DCMAKE_PREFIX_PATH="$DEPS_DIR" || {
        log_error "libzip cmake failed"
        return 1
    }
    make -j$(nproc) || {
        log_error "libzip build failed"
        return 1
    }
    make install || {
        log_error "libzip install failed"
        return 1
    }

    mark_completed "libzip"

    log_info "libzip built successfully"
}

# Build libpng
build_libpng() {
    if is_completed "libpng"; then
        log_info "libpng already built - skipping"
        return 0
    fi

    log_info "Building libpng $LIBPNG_VERSION..."

    local filename="libpng-$LIBPNG_VERSION.tar.gz"

    safe_download \
        "https://download.sourceforge.net/libpng/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "libpng-$LIBPNG_VERSION" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract libpng"
            return 1
        }
    fi

    cd "$BUILD_DIR/libpng-$LIBPNG_VERSION"

    ./configure --prefix="$DEPS_DIR" || {
        log_error "libpng configure failed"
        return 1
    }
    make -j$(nproc) || {
        log_error "libpng build failed"
        return 1
    }
    make install || {
        log_error "libpng install failed"
        return 1
    }

    mark_completed "libpng"

    log_info "libpng built successfully"
}

# Build libjpeg
build_libjpeg() {
    if is_completed "libjpeg"; then
        log_info "libjpeg already built - skipping"
        return 0
    fi

    log_info "Building libjpeg $LIBJPEG_VERSION..."

    local filename="jpegsrc.v$LIBJPEG_VERSION.tar.gz"

    safe_download \
        "http://www.ijg.org/files/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "jpeg-$LIBJPEG_VERSION" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract libjpeg"
            return 1
        }
    fi

    cd "$BUILD_DIR/jpeg-$LIBJPEG_VERSION"

    ./configure --prefix="$DEPS_DIR" || {
        log_error "libjpeg configure failed"
        return 1
    }
    make -j$(nproc) || {
        log_error "libjpeg build failed"
        return 1
    }
    make install || {
        log_error "libjpeg install failed"
        return 1
    }

    mark_completed "libjpeg"

    log_info "libjpeg built successfully"
}

# Build freetype
build_freetype() {
    if is_completed "freetype"; then
        log_info "freetype already built - skipping"
        return 0
    fi

    log_info "Building freetype $FREETYPE_VERSION..."

    local filename="freetype-$FREETYPE_VERSION.tar.gz"

    safe_download \
        "https://download.savannah.gnu.org/releases/freetype/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "freetype-$FREETYPE_VERSION" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract freetype"
            return 1
        }
    fi

    cd "$BUILD_DIR/freetype-$FREETYPE_VERSION"

    # --without-harfbuzz: harfbuzz pulls fontconfig->glib->pcre2@PCRE2_10.47
    # (system version), conflicting with our compiled PCRE2 10.42.
    # --without-brotli: avoids pulling system libbrotli.
    # PHP GD only needs basic font rendering; neither is required for image work.
    ./configure --prefix="$DEPS_DIR" \
        --without-harfbuzz \
        --without-brotli || {
        log_error "freetype configure failed"
        return 1
    }
    make -j$(nproc) || {
        log_error "freetype build failed"
        return 1
    }
    make install || {
        log_error "freetype install failed"
        return 1
    }

    mark_completed "freetype"

    log_info "freetype built successfully"
}

# Build ICU
build_icu() {
    if is_completed "icu"; then
        log_info "ICU already built - skipping"
        return 0
    fi

    log_info "Building ICU..."

    local filename="icu4c-${ICU_VERSION}-sources.tgz"

    safe_download \
        "https://github.com/unicode-org/icu/releases/download/release-${ICU_VERSION}/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "icu" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract ICU"
            return 1
        }
    fi

    cd "$BUILD_DIR/icu/source"

    ./configure --prefix="$DEPS_DIR" || {
        log_error "ICU configure failed"
        return 1
    }
    make -j$(nproc) || {
        log_error "ICU build failed"
        return 1
    }
    make install || {
        log_error "ICU install failed"
        return 1
    }

    mark_completed "icu"

    log_info "ICU built successfully"
}

# Build ncurses
build_ncurses() {
    if is_completed "ncurses"; then
        log_info "ncurses already built - skipping"
        return 0
    fi

    log_info "Building ncurses $NCURSES_VERSION..."

    local filename="ncurses-$NCURSES_VERSION.tar.gz"

    safe_download \
        "https://ftp.gnu.org/gnu/ncurses/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "ncurses-$NCURSES_VERSION" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract ncurses"
            return 1
        }
    fi

    cd "$BUILD_DIR/ncurses-$NCURSES_VERSION"

    # Disable C++ bindings and other problematic features
    ./configure --prefix="$DEPS_DIR" \
        --with-shared \
        --without-cxx \
        --without-cxx-binding \
        --without-ada \
        --without-debug \
        --enable-widec \
        --with-termlib || {
        log_error "ncurses configure failed"
        return 1
    }

    make -j$(nproc) || {
        log_error "ncurses build failed"
        return 1
    }
    make install || {
        log_error "ncurses install failed"
        return 1
    }

    mark_completed "ncurses"

    log_info "ncurses built successfully"
}

# Build libaio
build_libaio() {
    if is_completed "libaio"; then
        log_info "libaio already built - skipping"
        return 0
    fi

    log_info "Building libaio $LIBAIO_VERSION..."

    local filename="libaio-libaio-$LIBAIO_VERSION.tar.gz"

    safe_download \
        "https://pagure.io/libaio/archive/libaio-$LIBAIO_VERSION/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "libaio-libaio-$LIBAIO_VERSION" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract libaio"
            return 1
        }
    fi

    cd "$BUILD_DIR/libaio-libaio-$LIBAIO_VERSION"

    make prefix="$DEPS_DIR" -j$(nproc) || {
        log_error "libaio build failed"
        return 1
    }
    make prefix="$DEPS_DIR" install || {
        log_error "libaio install failed"
        return 1
    }

    mark_completed "libaio"

    log_info "libaio built successfully"
}

# Build PostgreSQL (libpq + server)
build_postgresql() {
    if is_completed "postgresql"; then
        log_info "PostgreSQL already built - skipping"
        return 0
    fi

    log_info "Building PostgreSQL $POSTGRESQL_VERSION (libpq + server)..."

    local filename="postgresql-$POSTGRESQL_VERSION.tar.gz"

    safe_download \
        "https://ftp.postgresql.org/pub/source/v$POSTGRESQL_VERSION/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "postgresql-$POSTGRESQL_VERSION" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract PostgreSQL"
            return 1
        }
    fi

    cd "$BUILD_DIR/postgresql-$POSTGRESQL_VERSION"

    # --without-readline avoids system readline/ncurses conflict.
    # --without-icu avoids a second ICU link; PHP uses our ICU directly.
    # We build the full server so pg_ctl/initdb are available, but PHP only
    # needs libpq from $DEPS_DIR/lib and headers from $DEPS_DIR/include.
    ./configure --prefix="$STACK_DIR/postgresql" \
        --with-openssl \
        --with-openssl-dir="$DEPS_DIR" \
        --without-readline \
        --without-icu \
        --without-ldap \
        --without-gssapi || {
        log_error "PostgreSQL configure failed"
        return 1
    }

    # Build only the libraries and server binaries we need
    make -j$(nproc) -C src/interfaces/libpq || {
        log_error "PostgreSQL libpq build failed"
        return 1
    }
    make -j$(nproc) -C src/bin/pg_ctl || {
        log_warn "pg_ctl build failed (non-fatal)"
    }
    make -j$(nproc) -C src/bin/initdb || {
        log_warn "initdb build failed (non-fatal)"
    }
    make -j$(nproc) || {
        log_error "PostgreSQL full build failed"
        return 1
    }
    make install || {
        log_error "PostgreSQL install failed"
        return 1
    }

    # Symlink libpq into $DEPS_DIR so PHP configure finds it via --with-pgsql
    ln -sf "$STACK_DIR/postgresql/lib/libpq.so"* "$DEPS_DIR/lib/" 2>/dev/null || true
    ln -sf "$STACK_DIR/postgresql/lib/libpq.a"  "$DEPS_DIR/lib/" 2>/dev/null || true
    cp -rn "$STACK_DIR/postgresql/include/." "$DEPS_DIR/include/" 2>/dev/null || true
    # pkg-config file
    mkdir -p "$DEPS_DIR/lib/pkgconfig"
    cp "$STACK_DIR/postgresql/lib/pkgconfig/libpq.pc" "$DEPS_DIR/lib/pkgconfig/" 2>/dev/null || true

    mark_completed "postgresql"
    log_info "PostgreSQL built successfully"
}

# Build libsodium
build_sodium() {
    if is_completed "sodium"; then
        log_info "libsodium already built - skipping"
        return 0
    fi
    log_info "Building libsodium $SODIUM_VERSION..."

    local filename="libsodium-$SODIUM_VERSION.tar.gz"

    # Try multiple mirrors
    safe_download \
        "https://download.libsodium.org/libsodium/releases/$filename" \
        "$filename" || \
    safe_download \
        "https://github.com/jedisct1/libsodium/releases/download/$SODIUM_VERSION/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "libsodium-$SODIUM_VERSION" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract libsodium"
            return 1
        }
    fi

    cd "$BUILD_DIR/libsodium-$SODIUM_VERSION"

    ./configure --prefix="$DEPS_DIR" --disable-shared --enable-static || {
        log_error "libsodium configure failed"
        return 1
    }

    make -j$(nproc) || {
        log_error "libsodium build failed"
        return 1
    }

    make install || {
        log_error "libsodium install failed"
        return 1
    }

    mark_completed "sodium"

    log_info "libsodium built successfully"
}

# Build libxslt (required for PHP --with-xsl)
build_libxslt() {
    if is_completed "libxslt"; then
        log_info "libxslt already built - skipping"
        return 0
    fi

    log_info "Building libxslt $LIBXSLT_VERSION..."

    local filename="libxslt-$LIBXSLT_VERSION.tar.xz"

    safe_download \
        "https://download.gnome.org/sources/libxslt/1.1/$filename" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "libxslt-$LIBXSLT_VERSION" ]; then
        tar -xJf "$filename" || {
            log_error "Failed to extract libxslt"
            return 1
        }
    fi

    cd "$BUILD_DIR/libxslt-$LIBXSLT_VERSION"

    ./configure --prefix="$DEPS_DIR" \
        --with-libxml-prefix="$DEPS_DIR" \
        --without-python \
        --without-crypto || {
        log_error "libxslt configure failed"
        return 1
    }
    make -j$(nproc) || {
        log_error "libxslt build failed"
        return 1
    }
    make install || {
        log_error "libxslt install failed"
        return 1
    }

    mark_completed "libxslt"
    log_info "libxslt built successfully"
}

# Build all dependencies
build_all_dependencies() {
    if is_completed "dependencies"; then
        log_info "dependencies already built - skipping"
        return 0
    fi

    log_info "Building all dependencies (this will take a while)..."

    setup_build_flags

    # Build in order with error checking
    build_cmake || { log_error "CMake failed"; exit 1; }
    build_zlib || { log_error "zlib failed"; exit 1; }
    build_sodium || { log_error "Sodium failed"; exit 1; }
    build_openssl || { log_error "OpenSSL failed"; exit 1; }
    build_pcre2 || { log_error "PCRE2 failed"; exit 1; }
    build_libxml2 || { log_error "libxml2 failed"; exit 1; }
    build_libxslt || { log_error "libxslt failed"; exit 1; }
    build_curl || { log_error "curl failed"; exit 1; }
    build_oniguruma || { log_error "oniguruma failed"; exit 1; }
    build_sqlite || { log_error "SQLite failed"; exit 1; }
    build_libzip || { log_error "libzip failed"; exit 1; }
    build_libpng || { log_error "libpng failed"; exit 1; }
    build_libjpeg || { log_error "libjpeg failed"; exit 1; }
    build_freetype || { log_error "freetype failed"; exit 1; }
    build_icu || { log_error "ICU failed"; exit 1; }
    build_ncurses || { log_error "ncurses failed"; exit 1; }
    build_libaio || { log_error "libaio failed"; exit 1; }
    build_postgresql || { log_error "PostgreSQL failed"; exit 1; }

    mark_completed "dependencies"
    log_info "All dependencies built successfully"
}

# Install Nginx
install_nginx() {
    if is_completed "nginx"; then
        log_info "Nginx already built - skipping"
        return 0
    fi

    log_info "Installing Nginx $NGINX_VERSION..."

    setup_build_flags

    download_extract \
        "http://nginx.org/download/nginx-$NGINX_VERSION.tar.gz" \
        "nginx-$NGINX_VERSION"

    cd "$BUILD_DIR/nginx-$NGINX_VERSION"

    ./configure \
        --prefix="$STACK_DIR/nginx" \
        --sbin-path="$STACK_DIR/nginx/nginx" \
        --conf-path="$STACK_DIR/nginx/conf/nginx.conf" \
        --error-log-path="$STACK_DIR/nginx/logs/error.log" \
        --http-log-path="$STACK_DIR/nginx/logs/access.log" \
        --pid-path="$STACK_DIR/nginx/nginx.pid" \
        --lock-path="$STACK_DIR/nginx/nginx.lock" \
        --with-pcre="$BUILD_DIR/pcre2-$PCRE2_VERSION" \
        --with-zlib="$BUILD_DIR/zlib-$ZLIB_VERSION" \
        --with-openssl="$BUILD_DIR/openssl-$OPENSSL_VERSION" \
        --with-http_ssl_module \
        --with-http_v2_module \
        --with-http_realip_module \
        --with-http_addition_module \
        --with-http_sub_module \
        --with-http_dav_module \
        --with-http_flv_module \
        --with-http_mp4_module \
        --with-http_gunzip_module \
        --with-http_gzip_static_module \
        --with-http_random_index_module \
        --with-http_secure_link_module \
        --with-http_stub_status_module \
        --with-http_auth_request_module

    make -j$(nproc)
    make install

    mark_completed "nginx"

    log_info "Nginx installed successfully"
}

# Configure Nginx
configure_nginx() {
    log_info "Configuring Nginx..."

    cat > "$STACK_DIR/nginx/conf/nginx.conf" << 'EOF'
worker_processes auto;
error_log logs/error.log;
pid nginx.pid;

events {
    worker_connections 1024;
}

http {
    include mime.types;
    default_type application/octet-stream;

    sendfile on;
    keepalive_timeout 65;

    server {
        listen 8080;
        server_name localhost;
        root STACK_DIR/www;
        index index.php index.html index.htm;

        location / {
            try_files $uri $uri/ /index.php?$query_string;
        }

        location ~ \.php$ {
            fastcgi_pass unix:STACK_DIR/php/current/php-fpm.sock;
            fastcgi_index index.php;
            fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
            include fastcgi_params;
        }

        location ~ /\.ht {
            deny all;
        }
    }
}
EOF

    sed -i "s|STACK_DIR|$STACK_DIR|g" "$STACK_DIR/nginx/conf/nginx.conf"
}

# Install PHP version
install_php() {
    local version=$1
    local major_minor=$(echo $version | cut -d. -f1,2)

    # Check if this PHP version is already installed
    if is_completed "php-$version"; then
        log_info "PHP $version already installed - skipping"
        return 0
    fi

    # Also check if the PHP binary actually exists
    if [ -f "$STACK_DIR/php/$major_minor/bin/php" ]; then
        log_info "PHP $version already installed (binary exists) - skipping"
        mark_completed "php-$version"
        return 0
    fi

    log_info "Installing PHP $version..."

    setup_build_flags

    # Use safe_download and manual extraction
    local filename="php-$version.tar.gz"

    safe_download \
        "https://www.php.net/distributions/php-$version.tar.gz" \
        "$filename" || return 1

    cd "$BUILD_DIR"

    if [ ! -d "php-$version" ]; then
        tar -xzf "$filename" || {
            log_error "Failed to extract PHP"
            return 1
        }
    fi

    cd "$BUILD_DIR/php-$version"

    # LIBS=-lz -lm is required for the GD link test: PHP configure probes
    # GD by compiling a small test binary linking against libpng/libjpeg/
    # freetype, which in turn depend on zlib and libm. Without LIBS those
    # transitive deps go unresolved and the probe fails even when all headers
    # are found. WEBP/AVIF/XPM are disabled because we do not compile them;
    # leaving them unset causes the GD build test to fail on PHP 8.2+.
    # Flag notes for PHP 8.x:
    # --with-zlib-dir     removed in PHP 8.0 → zlib via pkg-config (CPPFLAGS/LDFLAGS)
    # --enable-zip        removed in PHP 8.0 → always built when libzip found
    # --with-icu-dir      removed in PHP 8.0 → ICU via pkg-config / PATH
    # --with-png-dir      removed in PHP 7.4 → libpng via pkg-config
    # --with-onig         still valid in PHP 8; kept as-is
    # --with-xsl          requires libxslt compiled into $DEPS_DIR
    LIBS="-lz -lm" \
    ./configure \
        --prefix="$STACK_DIR/php/$major_minor" \
        --enable-fpm \
        --with-fpm-user="$USER" \
        --with-fpm-group="$(id -gn)" \
        --with-config-file-path="$STACK_DIR/php/$major_minor/etc" \
        --with-config-file-scan-dir="$STACK_DIR/php/$major_minor/etc/conf.d" \
        --with-openssl="$DEPS_DIR" \
        --with-curl="$DEPS_DIR" \
        --enable-mbstring \
        --with-zip="$DEPS_DIR" \
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
        --with-pdo-sqlite="$DEPS_DIR" \
        --with-pgsql="$DEPS_DIR" \
        --with-pdo-pgsql="$DEPS_DIR" \
        --with-jpeg="$DEPS_DIR" \
        --with-freetype="$DEPS_DIR" \
        --enable-gd \
        --without-webp \
        --without-avif \
        --without-xpm \
        --with-zlib="$DEPS_DIR" \
        --enable-ctype \
        --with-sodium \
        --with-xsl="$DEPS_DIR" \
        --enable-xml \
        --enable-opcache \
        --enable-opcache-jit \
        --with-libxml="$DEPS_DIR" \
        --with-onig="$DEPS_DIR" \
        --disable-cgi || {
        log_error "PHP configure failed"
        return 1
    }

    make -j$(nproc) || {
        log_error "PHP build failed"
        return 1
    }
    make install || {
        log_error "PHP install failed"
        return 1
    }

    # ── php.ini setup ────────────────────────────────────────────────────────
    # Copy base php.ini
    if [ -f "php.ini-development" ]; then
        cp php.ini-development "$STACK_DIR/php/$major_minor/etc/php.ini"
    fi

    # Locate the opcache.so that was just compiled.
    # The extensions dir name encodes the API version (e.g. no-debug-non-zts-20230831)
    # and changes between PHP releases, so we find it dynamically.
    local ext_dir
    ext_dir=$("$STACK_DIR/php/$major_minor/bin/php-config" --extension-dir 2>/dev/null || true)
    local opcache_so="$ext_dir/opcache.so"

    if [ -f "$opcache_so" ]; then
        # OPcache MUST be loaded as a zend_extension, not a normal extension.
        # It also must appear before any [PHP] section content so it is loaded
        # first. We prepend it at the very top of php.ini.
        local tmp_ini
        tmp_ini=$(mktemp)
        {
            echo "[PHP]"
            echo "zend_extension=\"${opcache_so}\""
            echo ""
            # Skip any existing [PHP] header line so we don't duplicate it
            grep -v '^\[PHP\]' "$STACK_DIR/php/$major_minor/etc/php.ini"
        } > "$tmp_ini"
        mv "$tmp_ini" "$STACK_DIR/php/$major_minor/etc/php.ini"
        log_info "OPcache configured for PHP $major_minor ($opcache_so)"
    else
        log_warn "opcache.so not found for PHP $major_minor — OPcache not configured"
    fi

    # ── conf.d override file ──────────────────────────────────────────────────
    # Drop a webstack.ini into the scan dir.  Users can edit this file to
    # tune settings without touching the main php.ini.  It is safe to re-run
    # the installer; the file is only written if it does not already exist so
    # manual edits are preserved.
    local confd="$STACK_DIR/php/$major_minor/etc/conf.d"
    mkdir -p "$confd"

    if [ ! -f "$confd/webstack.ini" ]; then
        cat > "$confd/webstack.ini" << 'WEBSTACK_INI_EOF'
; ============================================================
; WebStack PHP override settings
; Edit this file to customise PHP for your projects.
; Changes take effect after restarting PHP-FPM (webstack-stop / webstack-start).
; DO NOT edit php.ini directly — use this file instead.
; ============================================================

; ── Memory & input limits (Moodle recommends >= 256M) ──────
memory_limit = 256M
max_input_vars = 5000
max_input_time = 300
post_max_size = 256M
upload_max_filesize = 256M

; ── Execution time ──────────────────────────────────────────
max_execution_time = 300
default_socket_timeout = 60

; ── Error handling (development — tighten for production) ───
error_reporting = E_ALL
display_errors = On
display_startup_errors = On
log_errors = On
; error_log is set by PHP-FPM pool config

; ── Session ─────────────────────────────────────────────────
session.gc_maxlifetime = 7200
session.cookie_secure = 0
session.cookie_httponly = 1

; ── OPcache tuning ──────────────────────────────────────────
; The zend_extension line is written to php.ini automatically by the
; installer.  These directives only take effect when OPcache is loaded.
opcache.enable = 1
opcache.enable_cli = 0
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 2
opcache.save_comments = 1
; JIT (PHP 8+) — set to 0 to disable
opcache.jit = tracing
opcache.jit_buffer_size = 64M

; ── Moodle-specific recommendations ─────────────────────────
; Moodle requires ctype, xml, soap, intl, zip, gd, mbstring, curl, sodium.
; All are compiled in.  Uncomment lines below if Moodle warns about them.
; extension = intl
; extension = soap
WEBSTACK_INI_EOF
        log_info "Created $confd/webstack.ini"
    else
        log_info "conf.d/webstack.ini already exists — skipping (preserving edits)"
    fi

    # Create PHP-FPM configuration
    mkdir -p "$STACK_DIR/php/$major_minor/logs"
    cat > "$STACK_DIR/php/$major_minor/etc/php-fpm.conf" << EOF
[global]
pid = $STACK_DIR/php/$major_minor/php-fpm.pid
error_log = $STACK_DIR/php/$major_minor/logs/php-fpm.log

[www]
user = $USER
group = $(id -gn)
listen = $STACK_DIR/php/$major_minor/php-fpm.sock
listen.owner = $USER
listen.group = $(id -gn)
pm = dynamic
pm.max_children = 5
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
EOF

    # Only mark as completed if the PHP binary was actually created
    if [ -f "$STACK_DIR/php/$major_minor/bin/php" ]; then
        mark_completed "php-$version"
        log_info "PHP $version installed successfully"
    else
        log_error "PHP $version installation failed - binary not found"
        return 1
    fi
}

# Install MariaDB
install_mariadb() {
    if is_completed "mariadb"; then
        log_info "MariaDB already built - skipping"
        return 0
    fi

    log_info "Installing MariaDB $MARIADB_VERSION..."

    setup_build_flags

    download_extract \
        "https://archive.mariadb.org/mariadb-$MARIADB_VERSION/source/mariadb-$MARIADB_VERSION.tar.gz" \
        "mariadb-$MARIADB_VERSION"

    cd "$BUILD_DIR/mariadb-$MARIADB_VERSION"
    mkdir -p build && cd build

    "$DEPS_DIR/bin/cmake" .. \
        -DCMAKE_INSTALL_PREFIX="$STACK_DIR/mariadb" \
        -DMYSQL_DATADIR="$STACK_DIR/mariadb/data" \
        -DCMAKE_PREFIX_PATH="$DEPS_DIR" \
        -DWITH_SSL="$DEPS_DIR" \
        -DWITH_ZLIB=bundled \
        -DZLIB_INCLUDE_DIR="$DEPS_DIR/include" \
        -DZLIB_LIBRARY="$DEPS_DIR/lib/libz.so" \
        -DWITH_EMBEDDED_SERVER=OFF \
        -DWITH_UNIT_TESTS=OFF \
        -DPLUGIN_AUTH_GSSAPI_CLIENT=OFF \
        -DPLUGIN_AUTH_GSSAPI=NO \
        -DPLUGIN_ROCKSDB=NO \
        -DPLUGIN_MROONGA=NO \
        -DPLUGIN_SPIDER=NO \
        -DPLUGIN_OQGRAPH=NO \
        -DPLUGIN_TOKUDB=NO \
        -DPLUGIN_CONNECT=NO || {
        log_error "MariaDB cmake failed"
        return 1
    }

    # Build server and essential tools (skip interactive client due to ncurses issues)
    make -j$(nproc) mariadbd mariadb-admin mariadb-dump mariadb-check || {
        log_warn "Parallel build failed, trying with -j2..."
        make clean
        make -j2 mariadbd mariadb-admin mariadb-dump mariadb-check || {
            log_warn "Still failing, trying with -j1..."
            make clean
            make -j1 mariadbd mariadb-admin mariadb-dump mariadb-check || {
                log_error "MariaDB build failed"
                return 1
            }
        }
    }

    make install || {
        log_error "MariaDB install failed"
        return 1
    }

    # Initialize database.
    # --auth-root-authentication-method=normal: root gets mysql_native_password
    # auth so PHP/phpMyAdmin can connect via TCP with a password.
    # --no-defaults: prevents reading stray system my.cnf files on CI runners
    # (e.g. /etc/mysql/my.cnf) that conflict with our isolated paths and cause
    # "Broken pipe" bootstrap failures.
    # ulimit -n 65536: mariadbd --bootstrap opens many file descriptors;
    # CI runners default to 1024 which is too low and causes broken pipes.
    local init_log="$STACK_DIR/mariadb/logs/init.log"
    mkdir -p "$STACK_DIR/mariadb/logs"

    run_mariadb_init() {
        ulimit -n 65536 2>/dev/null || true
        "$STACK_DIR/mariadb/scripts/mariadb-install-db" \
            --no-defaults \
            --basedir="$STACK_DIR/mariadb" \
            --datadir="$STACK_DIR/mariadb/data" \
            --user="$USER" \
            --auth-root-authentication-method=normal \
            --innodb-log-file-size=48M \
            --innodb-buffer-pool-size=64M \
            "$@"
    }

    if ! run_mariadb_init 2>&1 | tee "$init_log"; then
        log_warn "First init attempt failed, retrying with --verbose..."
        rm -rf "$STACK_DIR/mariadb/data"/*
        if ! run_mariadb_init --verbose 2>&1 | tee "$init_log"; then
            log_error "MariaDB database initialization failed"
            log_error "See: $init_log"
            return 1
        fi
    fi

    mark_completed "mariadb"

    log_info "MariaDB installed successfully"
    log_info "Note: Interactive 'mariadb' client was skipped due to ncurses compatibility"
    log_info "Use mariadb-admin or connect via PHP/applications instead"
}

# Configure MariaDB
configure_mariadb() {
    log_info "Configuring MariaDB..."

    cat > "$STACK_DIR/mariadb/my.cnf" << EOF
[mysqld]
basedir = $STACK_DIR/mariadb
datadir = $STACK_DIR/mariadb/data
port = 3306
socket = $STACK_DIR/mariadb/mariadb.sock
pid-file = $STACK_DIR/mariadb/mariadb.pid
log-error = $STACK_DIR/mariadb/logs/error.log
# Bind to localhost only — allows both socket and 127.0.0.1 TCP connections.
# PHP/phpMyAdmin must use host=127.0.0.1 (not "localhost") to go via TCP.
bind-address = 127.0.0.1
# Skip reverse DNS lookups — prevents auth delays and failures over TCP.
skip-name-resolve

[client]
socket = $STACK_DIR/mariadb/mariadb.sock
port = 3306
EOF
    # MariaDB refuses to read world-writable config files (security policy).
    # cat heredoc creates 0666; restrict to owner-read-only.
    chmod 0600 "$STACK_DIR/mariadb/my.cnf"
}

# Configure MariaDB authentication
# Starts MariaDB briefly to set the root password and create a dedicated
# webstack user that phpMyAdmin and PHP apps can connect with.
configure_mariadb_auth() {
    if is_completed "mariadb_auth"; then
        log_info "MariaDB auth already configured - skipping"
        return 0
    fi

    log_info "Configuring MariaDB authentication..."

    local MYSQL_BIN="$STACK_DIR/mariadb/bin"
    # Use a temp socket in /tmp so path length is never an issue and it is
    # guaranteed writable regardless of $STACK_DIR permissions.
    local TEMP_SOCKET="/tmp/mariadb-setup-$$.sock"
    local MYSQL_SOCKET="$STACK_DIR/mariadb/mariadb.sock"
    local ROOT_PASSWORD="123456"
    local APP_USER="webstack"
    local APP_PASSWORD="webstack"
    local AUTH_LOG="$STACK_DIR/mariadb/logs/auth-setup.log"
    mkdir -p "$STACK_DIR/mariadb/logs"

    # Start mariadbd directly (not via mariadbd-safe) so we control the PID
    # cleanly.  --skip-grant-tables lets us run ALTER USER without a password.
    # We use a dedicated temp socket so path issues with my.cnf don't interfere.
    ulimit -n 65536 2>/dev/null || true
    "$MYSQL_BIN/mariadbd" \
        --no-defaults \
        --basedir="$STACK_DIR/mariadb" \
        --datadir="$STACK_DIR/mariadb/data" \
        --socket="$TEMP_SOCKET" \
        --pid-file="/tmp/mariadb-setup-$$.pid" \
        --skip-networking \
        --skip-grant-tables \
        --skip-name-resolve \
        --innodb-buffer-pool-size=64M \
        --log-error="$AUTH_LOG" \
        --daemonize || {
        log_error "MariaDB failed to start for auth setup. Log: $AUTH_LOG"
        return 1
    }

    # Wait for temp socket to appear (up to 60 seconds)
    local waited=0
    while [ ! -S "$TEMP_SOCKET" ] && [ $waited -lt 60 ]; do
        sleep 1
        (( waited++ )) || true
    done

    if [ ! -S "$TEMP_SOCKET" ]; then
        log_error "MariaDB socket did not appear after ${waited}s during auth setup"
        log_error "Log: $AUTH_LOG"
        cat "$AUTH_LOG" 2>/dev/null || true
        return 1
    fi

    log_info "MariaDB started for auth setup (${waited}s), configuring users..."

    # Run all user management SQL in one batch
    "$MYSQL_BIN/mariadb" --socket="$TEMP_SOCKET" -u root << SQLEOF
FLUSH PRIVILEGES;
ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('$ROOT_PASSWORD');
CREATE USER IF NOT EXISTS 'root'@'127.0.0.1' IDENTIFIED BY '$ROOT_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'127.0.0.1' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS '$APP_USER'@'localhost'  IDENTIFIED BY '$APP_PASSWORD';
CREATE USER IF NOT EXISTS '$APP_USER'@'127.0.0.1' IDENTIFIED BY '$APP_PASSWORD';
GRANT ALL PRIVILEGES ON *.* TO '$APP_USER'@'localhost'  WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '$APP_USER'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQLEOF

    # Graceful shutdown via the temp socket
    "$MYSQL_BIN/mariadb-admin" --socket="$TEMP_SOCKET" -u root \
        --password="$ROOT_PASSWORD" shutdown 2>/dev/null || \
    "$MYSQL_BIN/mariadb-admin" --socket="$TEMP_SOCKET" -u root \
        shutdown 2>/dev/null || true

    # Wait for shutdown
    local sw=0
    while [ -S "$TEMP_SOCKET" ] && [ $sw -lt 15 ]; do
        sleep 1; (( sw++ )) || true
    done
    rm -f "$TEMP_SOCKET" "/tmp/mariadb-setup-$$.pid"

    mark_completed "mariadb_auth"
    log_info "MariaDB authentication configured"
    log_info "  root password : $ROOT_PASSWORD"
    log_info "  app user      : $APP_USER / $APP_PASSWORD"
    log_info "phpMyAdmin: host=127.0.0.1  user=root  password=$ROOT_PASSWORD"
}

# Configure PostgreSQL - initialize data directory, create postgres superuser
# with a known password, and create a default database.
configure_postgresql() {
    if is_completed "postgresql_configured"; then
        log_info "PostgreSQL already configured - skipping"
        return 0
    fi

    log_info "Configuring PostgreSQL..."

    local PGDATA="$STACK_DIR/postgresql/data"
    local PGLOG="$STACK_DIR/postgresql/logs"
    local PG_BIN="$STACK_DIR/postgresql/bin"
    local PG_PASSWORD="123456"

    mkdir -p "$PGDATA" "$PGLOG"

    # Remove any previous partial init
    rm -rf "$PGDATA"/*

    # initdb with explicit superuser "postgres" and md5 password auth.
    # --pwfile feeds the password without it appearing in process list.
    local pwfile
    pwfile=$(mktemp)
    echo "$PG_PASSWORD" > "$pwfile"

    "$PG_BIN/initdb"         -D "$PGDATA"         -U postgres         --pwfile="$pwfile"         --auth=md5         --auth-local=trust         --encoding=UTF8         --locale=C         --no-instructions || {
        rm -f "$pwfile"
        log_error "PostgreSQL initdb failed"
        return 1
    }
    rm -f "$pwfile"

    # Append a pg_hba.conf entry that allows password login over TCP for all
    # users (needed for PHP PDO connections via host=127.0.0.1).
    cat >> "$PGDATA/pg_hba.conf" << 'HBAEOF'
# webstack: allow password auth from localhost for all users/databases
host    all             all             127.0.0.1/32            md5
host    all             all             ::1/128                 md5
HBAEOF

    # Start PostgreSQL temporarily to create the default database
    "$PG_BIN/pg_ctl" -D "$PGDATA" -l "$PGLOG/postgresql.log" start -w || {
        log_error "PostgreSQL failed to start during configuration"
        return 1
    }

    # Create a default "webstack" database owned by postgres
    "$PG_BIN/createdb" -U postgres webstack 2>/dev/null || true

    # Stop again - will be started properly by start.sh
    "$PG_BIN/pg_ctl" -D "$PGDATA" stop -w || true

    mark_completed "postgresql_configured"
    log_info "PostgreSQL configured successfully"
    log_info "  Superuser : postgres"
    log_info "  Password  : $PG_PASSWORD"
    log_info "  Database  : webstack"
    log_info "  Port      : 5432"
}

# Create environment setup script
create_env_script() {
    cat > "$STACK_DIR/env.sh" << EOF
#!/bin/bash
export WEBSTACK_HOME="$STACK_DIR"
export PATH="$STACK_DIR/bin:\$PATH"
# LD_LIBRARY_PATH is intentionally NOT set here.
# All binaries have $DEPS_DIR/lib baked in via -rpath at compile time,
# so they find the right libs automatically without polluting the
# system linker search path.
export PKG_CONFIG_PATH="$DEPS_DIR/lib/pkgconfig:\$PKG_CONFIG_PATH"
EOF
    chmod +x "$STACK_DIR/env.sh"
}

# Create management scripts
create_management_scripts() {
    log_info "Creating management scripts..."

    # Start script
    cat > "$STACK_DIR/bin/start.sh" << 'EOF'
#!/bin/bash
STACK_DIR="STACK_DIR_PLACEHOLDER"
DEPS_DIR="$STACK_DIR/deps"

# LD_LIBRARY_PATH is not needed - rpath is baked into all compiled binaries.

echo "Starting Web Stack..."

# Start PostgreSQL
PGDATA="$STACK_DIR/postgresql/data"
PGLOG="$STACK_DIR/postgresql/logs/postgresql.log"
if [ ! -f "$PGDATA/PG_VERSION" ]; then
    # Data dir missing - re-run configure_postgresql via the installer to set up properly.
    echo "PostgreSQL data directory not found. Please re-run the installer."
fi
if [ ! -f "$PGDATA/postmaster.pid" ]; then
    "$STACK_DIR/postgresql/bin/pg_ctl" -D "$PGDATA" -l "$PGLOG" start
    echo "PostgreSQL started"
else
    echo "PostgreSQL already running"
fi

# Start MariaDB
if [ ! -f "$STACK_DIR/mariadb/mariadb.pid" ]; then
    "$STACK_DIR/mariadb/bin/mariadbd-safe" --defaults-file="$STACK_DIR/mariadb/my.cnf" &
    echo "MariaDB started"
else
    echo "MariaDB already running"
fi

# Start PHP-FPM (current version)
if [ -L "$STACK_DIR/php/current" ]; then
    PHP_VER=$(basename $(readlink "$STACK_DIR/php/current"))
    if [ ! -f "$STACK_DIR/php/current/php-fpm.pid" ]; then
        "$STACK_DIR/php/current/sbin/php-fpm" -y "$STACK_DIR/php/current/etc/php-fpm.conf"
        echo "PHP-FPM $PHP_VER started"
    else
        echo "PHP-FPM already running"
    fi
else
    echo "No PHP version selected. Use: switch-php <version>"
fi

# Start Nginx
if [ ! -f "$STACK_DIR/nginx/nginx.pid" ]; then
    "$STACK_DIR/nginx/nginx"
    echo "Nginx started on http://localhost:8080"
else
    echo "Nginx already running"
fi

echo "Stack started successfully!"
EOF

    # Stop script
    cat > "$STACK_DIR/bin/stop.sh" << 'EOF'
#!/bin/bash
STACK_DIR="STACK_DIR_PLACEHOLDER"

echo "Stopping Web Stack..."

# Stop PostgreSQL
PGDATA="$STACK_DIR/postgresql/data"
if [ -f "$PGDATA/postmaster.pid" ]; then
    "$STACK_DIR/postgresql/bin/pg_ctl" -D "$PGDATA" stop
    echo "PostgreSQL stopped"
fi

# Stop Nginx
if [ -f "$STACK_DIR/nginx/nginx.pid" ]; then
    kill $(cat "$STACK_DIR/nginx/nginx.pid")
    echo "Nginx stopped"
fi

# Stop PHP-FPM
if [ -f "$STACK_DIR/php/current/php-fpm.pid" ]; then
    kill $(cat "$STACK_DIR/php/current/php-fpm.pid")
    echo "PHP-FPM stopped"
fi

# Stop MariaDB
if [ -f "$STACK_DIR/mariadb/mariadb.pid" ]; then
    "$STACK_DIR/mariadb/bin/mariadb-admin" --defaults-file="$STACK_DIR/mariadb/my.cnf" shutdown
    echo "MariaDB stopped"
fi

echo "Stack stopped successfully!"
EOF

    # Switch PHP version script
    cat > "$STACK_DIR/bin/switch-php.sh" << 'EOF'
#!/bin/bash
STACK_DIR="STACK_DIR_PLACEHOLDER"
VERSION=$1

if [ -z "$VERSION" ]; then
    echo "Usage: switch-php <version>"
    echo "Available versions:"
    ls "$STACK_DIR/php" | grep -E '^[0-9]+\.[0-9]+$'
    exit 1
fi

if [ ! -d "$STACK_DIR/php/$VERSION" ]; then
    echo "PHP $VERSION is not installed"
    exit 1
fi

# Stop current PHP-FPM
if [ -f "$STACK_DIR/php/current/php-fpm.pid" ]; then
    kill $(cat "$STACK_DIR/php/current/php-fpm.pid")
fi

# Switch version
rm -f "$STACK_DIR/php/current"
ln -s "$STACK_DIR/php/$VERSION" "$STACK_DIR/php/current"

# Start new PHP-FPM
"$STACK_DIR/php/current/sbin/php-fpm" -y "$STACK_DIR/php/current/etc/php-fpm.conf"

echo "Switched to PHP $VERSION"
EOF

    # MySQL client wrapper
    cat > "$STACK_DIR/bin/mysql.sh" << 'EOF'
#!/bin/bash
STACK_DIR="STACK_DIR_PLACEHOLDER"
DEPS_DIR="$STACK_DIR/deps"

# LD_LIBRARY_PATH is not needed - rpath is baked into the mariadb binary.

"$STACK_DIR/mariadb/bin/mysql" --defaults-file="$STACK_DIR/mariadb/my.cnf" "$@"
EOF

    # PostgreSQL client wrapper - defaults to postgres superuser
    cat > "$STACK_DIR/bin/psql.sh" << 'EOF'
#!/bin/bash
STACK_DIR="STACK_DIR_PLACEHOLDER"
# Default to postgres superuser if no -U flag is given
if [[ "$*" != *"-U"* && "$*" != *"--username"* ]]; then
    exec "$STACK_DIR/postgresql/bin/psql" -U postgres "$@"
else
    exec "$STACK_DIR/postgresql/bin/psql" "$@"
fi
EOF

    # Replace placeholder
    sed -i "s|STACK_DIR_PLACEHOLDER|$STACK_DIR|g" "$STACK_DIR/bin"/*.sh

    # Make scripts executable
    chmod +x "$STACK_DIR/bin"/*.sh

    # Create symlinks
    mkdir -p "$HOME/.local/bin"
    ln -sf "$STACK_DIR/bin/start.sh" "$HOME/.local/bin/webstack-start"
    ln -sf "$STACK_DIR/bin/stop.sh" "$HOME/.local/bin/webstack-stop"
    ln -sf "$STACK_DIR/bin/switch-php.sh" "$HOME/.local/bin/webstack-php"
    ln -sf "$STACK_DIR/bin/mysql.sh" "$HOME/.local/bin/webstack-mysql"
    ln -sf "$STACK_DIR/bin/psql.sh" "$HOME/.local/bin/webstack-psql"
}

# Create test page
create_test_page() {
    cat > "$STACK_DIR/www/index.php" << 'EOF'
<?php
if (isset($_GET['info'])) {
    phpinfo();
} else {
?><!DOCTYPE html>
<html>
<head>
    <title>Portable Web Stack</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; background: #f5f5f5; }
        .container { background: white; padding: 30px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        h1 { color: #333; }
        .info { background: #e8f5e9; padding: 15px; border-radius: 4px; margin: 20px 0; }
        table { width: 100%; border-collapse: collapse; margin: 20px 0; }
        th, td { padding: 12px; text-align: left; border-bottom: 1px solid #ddd; }
        th { background: #f5f5f5; }
        .btn{display:inline-block;padding:10px 16px;background-color:#2563eb;color:#fff;text-decoration:none;border-radius:6px;font-weight:500;transition:background 0.2s ease,transform 0.1s ease;}
        .btn:hover{background-color:#1d4ed8;}
        .btn:active{transform:scale(0.98);}
        .btn-secondary{background-color:#6b7280;}
        .btn-secondary:hover{background-color:#4b5563;}
        .btn-danger{background-color:#dc2626;}
        .btn-danger:hover{background-color:#b91c1c;}
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 Portable Web Stack is Running!</h1>
        <div class="info">
            <strong>PHP Version:</strong> <a title="See phpinfo()" href="/index.php?info=1"><?php echo phpversion(); ?></a><br>
            <strong>Server:</strong> <?php echo $_SERVER['SERVER_SOFTWARE']; ?><br>
            <strong>Document Root:</strong> <?php echo $_SERVER['DOCUMENT_ROOT']; ?>
        </div>

        <h2>PHP Extensions</h2>
        <table>
            <?php
            $extensions = get_loaded_extensions();
            sort($extensions);
            foreach (array_chunk($extensions, 3) as $chunk) {
                echo "<tr>";
                foreach ($chunk as $ext) {
                    echo "<td>$ext</td>";
                }
                echo "</tr>";
            }
            ?>
        </table>
    </div>
    <p><a href="/index.php?info=1" class="btn">SEE PHP INFO</a></p>
</body>
</html><?php } ?>
EOF
}

# Main installation
main() {
    # If freetype was previously built without --without-harfbuzz, it will
    # drag system libglib into the PHP GD link test and cause the
    # pcre2@PCRE2_10.47 undefined reference error. Force a freetype rebuild
    # if the old build didn't use the isolation flags, and reset any PHP
    # versions that failed as a result.
    if is_completed "freetype" && ! grep -q "without-harfbuzz" "$BUILD_DIR/freetype-$FREETYPE_VERSION/config.log" 2>/dev/null; then
        log_warn "Detected freetype built without --without-harfbuzz; forcing rebuild to fix GD/glib conflict..."
        reset_build "freetype"
        reset_build "dependencies"
        rm -rf "$BUILD_DIR/freetype-$FREETYPE_VERSION"
        for php_ver in "${PHP_VERSIONS[@]}"; do
            reset_build "php-$php_ver"
        done
    fi

    log_info "Starting Portable Web Stack installation..."
    log_info "Installation directory: $STACK_DIR"
    log_info "Downloads directory: $DOWNLOAD_DIR"
    log_warn "This will take 1-2 hours depending on your CPU"

    echo ""
    echo "========================================"
    echo "IMPORTANT: Manual Download Option"
    echo "========================================"
    echo "If downloads fail, you can manually download files"
    echo "and place them in: $DOWNLOAD_DIR"
    echo ""
    echo "To see all download URLs, run:"
    echo "  grep 'safe_download' $0 | grep 'https://'"
    echo "========================================"
    echo ""

    read -p "Continue? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi

    check_minimal_tools
    setup_directories

    # Build all dependencies first
    build_all_dependencies

    # Install stack components
    install_nginx
    configure_nginx

    # Install PHP versions
    for php_ver in "${PHP_VERSIONS[@]}"; do
        install_php "$php_ver"
    done

    # Set default PHP version to first in array (fix symlink issue)
    local default_php=$(echo "${PHP_VERSIONS[0]}" | cut -d. -f1,2)
    if [ ! -L "$STACK_DIR/php/current" ] && [ -d "$STACK_DIR/php/$default_php" ]; then
        ln -sf "$STACK_DIR/php/$default_php" "$STACK_DIR/php/current"
        log_info "Set default PHP version to $default_php"
    elif [ -L "$STACK_DIR/php/current" ]; then
        log_info "PHP current symlink already exists: $(readlink "$STACK_DIR/php/current")"
    else
        log_warn "Could not create PHP current symlink - directory not found: $STACK_DIR/php/$default_php"
    fi

    install_mariadb
    configure_mariadb
    configure_mariadb_auth

    configure_postgresql

    create_env_script
    create_management_scripts
    create_test_page

    log_info "Installation complete!"
    echo ""
    echo "========================================"
    echo "Portable Web Stack installed!"
    echo "========================================"
    echo ""
    echo "Everything is self-contained in: $STACK_DIR"
    echo ""
    echo "Commands:"
    echo "  webstack-start       - Start all services"
    echo "  webstack-stop        - Stop all services"
    echo "  webstack-php <ver>   - Switch PHP version"
    echo "  webstack-mysql       - MySQL client"
  echo "  webstack-psql        - PostgreSQL client"
    echo ""
    echo "Web root: $STACK_DIR/www"
    echo "URL: http://localhost:8080"
    echo ""
    echo "Make sure ~/.local/bin is in your PATH:"
    echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.bashrc"
    echo "  source ~/.bashrc"
    echo ""
    echo "To start: webstack-start"
    echo ""
    echo "To move this stack to another machine:"
    echo "  1. Copy the entire $STACK_DIR directory"
    echo "  2. Update paths in scripts if needed"
}

main
