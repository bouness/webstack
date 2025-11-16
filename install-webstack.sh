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
PHP_VERSIONS=("8.4.13" "8.3.26" "8.2.28")
NGINX_VERSION="1.28.0"
MARIADB_VERSION="11.4.9"

# Dependency versions (will be compiled)
OPENSSL_VERSION="3.1.4"
PCRE2_VERSION="10.42"
ZLIB_VERSION="1.3"
LIBXML2_VERSION="2.11.5"
CURL_VERSION="8.4.0"
ONIGURUMA_VERSION="6.9.10"
SQLITE_VERSION="3440000"  # 3.44.0
LIBZIP_VERSION="1.10.1"
LIBPNG_VERSION="1.6.40"
LIBJPEG_VERSION="9e"
FREETYPE_VERSION="2.13.2"
ICU_VERSION="76_1"
NCURSES_VERSION="6.4"
LIBAIO_VERSION="0.3.113"
CMAKE_VERSION="3.27.7"

# Logging functions
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

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

    # Temporarily unset LD_LIBRARY_PATH to avoid conflicts
    local OLD_LD_LIBRARY_PATH="$LD_LIBRARY_PATH"
    unset LD_LIBRARY_PATH

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

    ./configure --prefix="$DEPS_DIR" \
        --with-openssl="$DEPS_DIR" \
        --with-zlib="$DEPS_DIR" || {
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

    # Add flags to suppress warnings-as-errors
    export CFLAGS="-O2 -Wno-error"

    ./configure --prefix="$DEPS_DIR" || {
        log_error "oniguruma configure failed"
        unset CFLAGS
        return 1
    }
    make -j$(nproc) || {
        log_error "oniguruma build failed"
        unset CFLAGS
        return 1
    }
    make install || {
        log_error "oniguruma install failed"
        unset CFLAGS
        return 1
    }

    unset CFLAGS

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

    ./configure --prefix="$DEPS_DIR" || {
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

    local filename="icu4c-${ICU_VERSION}-src.tgz"

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

# Build all dependencies
build_all_dependencies() {
    if is_completed "dependencies"; then
        log_info "dependencies already built - skipping"
        return 0
    fi

    log_info "Building all dependencies (this will take a while)..."

    export PKG_CONFIG_PATH="$DEPS_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"
    export LD_LIBRARY_PATH="$DEPS_DIR/lib:$LD_LIBRARY_PATH"
    export PATH="$DEPS_DIR/bin:$PATH"

    # Build in order with error checking
    build_cmake || { log_error "CMake failed"; exit 1; }
    build_zlib || { log_error "zlib failed"; exit 1; }
    build_openssl || { log_error "OpenSSL failed"; exit 1; }
    build_pcre2 || { log_error "PCRE2 failed"; exit 1; }
    build_libxml2 || { log_error "libxml2 failed"; exit 1; }
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

    export PKG_CONFIG_PATH="$DEPS_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"
    export LD_LIBRARY_PATH="$DEPS_DIR/lib:$LD_LIBRARY_PATH"

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

    export PKG_CONFIG_PATH="$DEPS_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"
    export LD_LIBRARY_PATH="$DEPS_DIR/lib:$LD_LIBRARY_PATH"
    export PATH="$DEPS_DIR/bin:$PATH"

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

    ./configure \
        --prefix="$STACK_DIR/php/$major_minor" \
        --enable-fpm \
        --with-fpm-user="$USER" \
        --with-fpm-group="$(id -gn)" \
        --with-config-file-path="$STACK_DIR/php/$major_minor/etc" \
        --with-config-file-scan-dir="$STACK_DIR/php/$major_minor/etc/conf.d" \
        --with-openssl="$DEPS_DIR" \
        --with-curl="$DEPS_DIR" \
        --with-zlib="$DEPS_DIR" \
        --enable-mbstring \
        --enable-zip \
        --with-zip="$DEPS_DIR" \
        --enable-bcmath \
        --enable-pcntl \
        --enable-ftp \
        --enable-exif \
        --enable-calendar \
        --enable-intl \
        --with-icu-dir="$DEPS_DIR" \
        --enable-soap \
        --enable-sockets \
        --with-mysqli \
        --with-pdo-mysql \
        --with-pdo-sqlite="$DEPS_DIR" \
        --with-jpeg="$DEPS_DIR" \
        --with-freetype="$DEPS_DIR" \
        --enable-gd \
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

    # Copy PHP configuration
    if [ -f "php.ini-development" ]; then
        cp php.ini-development "$STACK_DIR/php/$major_minor/etc/php.ini"
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

    export PKG_CONFIG_PATH="$DEPS_DIR/lib/pkgconfig:$PKG_CONFIG_PATH"
    export LD_LIBRARY_PATH="$DEPS_DIR/lib:$LD_LIBRARY_PATH"
    export PATH="$DEPS_DIR/bin:$PATH"

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
        -DWITH_ZLIB=system \
        -DZLIB_ROOT="$DEPS_DIR" \
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

    # Initialize database
    "$STACK_DIR/mariadb/scripts/mariadb-install-db" \
        --basedir="$STACK_DIR/mariadb" \
        --datadir="$STACK_DIR/mariadb/data" \
        --user="$USER" || {
        log_error "MariaDB database initialization failed"
        return 1
    }

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

[client]
socket = $STACK_DIR/mariadb/mariadb.sock
port = 3306
EOF
}

# Create environment setup script
create_env_script() {
    cat > "$STACK_DIR/env.sh" << EOF
#!/bin/bash
export WEBSTACK_HOME="$STACK_DIR"
export PATH="$STACK_DIR/bin:\$PATH"
export LD_LIBRARY_PATH="$DEPS_DIR/lib:\$LD_LIBRARY_PATH"
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

export LD_LIBRARY_PATH="$DEPS_DIR/lib:$LD_LIBRARY_PATH"

echo "Starting Web Stack..."

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

export LD_LIBRARY_PATH="$DEPS_DIR/lib:$LD_LIBRARY_PATH"

"$STACK_DIR/mariadb/bin/mysql" --defaults-file="$STACK_DIR/mariadb/my.cnf" "$@"
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
}

# Create test page
create_test_page() {
    cat > "$STACK_DIR/www/index.php" << 'EOF'
<!DOCTYPE html>
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
    </style>
</head>
<body>
    <div class="container">
        <h1>🚀 Portable Web Stack is Running!</h1>
        <div class="info">
            <strong>PHP Version:</strong> <?php echo phpversion(); ?><br>
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
</body>
</html>
EOF
}

# Main installation
main() {
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
