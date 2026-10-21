#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
IMAGE_NAME="winterhearted/php-fpm"
DOCKERFILE_NAME="Dockerfile"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log()     { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

source "$SCRIPT_DIR/engine.sh"

# Варианты образа — это php-X.Y/Dockerfile.<variant>, собираемые поверх уже
# готового базового образа. Нет файла — нет варианта, старые ветки живут как жили.
list_variants() {
    local php_dir=$1 f
    for f in "$php_dir"/Dockerfile.*; do
        [ -f "$f" ] || continue
        echo "${f##*/Dockerfile.}"
    done
}

# All available PHP versions.
# 8.6 сюда не входит намеренно: это пререлиз, у него свои теги (8.6-rc) и свой
# скрипт build-rc.sh. Через build.sh он собрался бы под именем 8.6/8.6-latest,
# то есть выглядел бы как обычная стабильная ветка.
ALL_VERSIONS=(5.3 5.4 5.5 5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1 8.2 8.3 8.4 8.5)

# Counters
TOTAL=0
SUCCESSFUL=0
FAILED=0

usage() {
    echo "Usage: $0 [OPTIONS] [VERSIONS...]"
    echo ""
    echo "Build PHP-FPM Docker images."
    echo ""
    echo "Options:"
    echo "  -n, --name NAME    Base image name (default: winterhearted/php-fpm)"
    echo "  -a, --all          Build all available versions"
    echo "  --no-cache         Build without cache (default)"
    echo "  --cache            Use Docker cache for faster builds"
    echo "  -h, --help         Show this help"
    echo ""
    echo "Available versions: ${ALL_VERSIONS[*]}"
    echo ""
    echo "Examples:"
    echo "  $0 8.3 8.4              Build PHP 8.3 and 8.4"
    echo "  $0 --all                Build all versions"
    echo "  $0 -n mycompany/php 8.3 Build with custom image name"
}

build_image() {
    local version=$1
    local php_dir="php-${version}"
    local version_tag="${IMAGE_NAME}:${version}"
    local latest_tag="${IMAGE_NAME}:${version}-latest"

    log "Building ${version_tag}"

    if [ ! -d "$php_dir" ]; then
        error "Directory $php_dir not found"
        return 1
    fi

    if [ ! -f "$php_dir/$DOCKERFILE_NAME" ]; then
        error "File $php_dir/$DOCKERFILE_NAME not found"
        return 1
    fi

    local build_args="-t $version_tag -t $latest_tag"
    if [ "$USE_CACHE" = "false" ]; then
        build_args="--no-cache --pull $build_args"
    fi

    if eng build $build_args "$php_dir"; then
        # Get exact PHP version from built image
        local exact_version
        exact_version=$(eng run --rm "$version_tag" php -r 'echo PHP_VERSION;' 2>/dev/null || true)

        if [ -n "$exact_version" ]; then
            eng tag "$version_tag" "${IMAGE_NAME}:${exact_version}"
            success "Built: $version_tag (${exact_version})"
        else
            success "Built: $version_tag"
        fi

        # Варианты собираем поверх свежесобранного базового образа — без --pull
        # и --no-cache, он локальный и заведомо только что построен
        local variant
        for variant in $(list_variants "$php_dir"); do
            log "Building ${version_tag}-${variant}"
            if eng build --build-arg "BASE_IMAGE=${version_tag}" \
                    -f "$php_dir/Dockerfile.${variant}" \
                    -t "${version_tag}-${variant}" \
                    -t "${latest_tag}-${variant}" "$php_dir"; then
                [ -n "$exact_version" ] && \
                    eng tag "${version_tag}-${variant}" "${IMAGE_NAME}:${exact_version}-${variant}"
                success "Built: ${version_tag}-${variant}"
            else
                error "Failed to build ${version_tag}-${variant}"
                FAILED=$((FAILED + 1))
                return 1
            fi
        done

        SUCCESSFUL=$((SUCCESSFUL + 1))
    else
        error "Failed to build $version_tag"
        FAILED=$((FAILED + 1))
        return 1
    fi
}

# Defaults
USE_CACHE="false"
VERSIONS=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)
            IMAGE_NAME="$2"
            shift 2
            ;;
        -a|--all)
            VERSIONS=("${ALL_VERSIONS[@]}")
            shift
            ;;
        --no-cache)
            USE_CACHE="false"
            shift
            ;;
        --cache)
            USE_CACHE="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            error "Unknown option: $1"
            usage
            exit 1
            ;;
        *)
            VERSIONS+=("$1")
            shift
            ;;
    esac
done

# Validate versions
if [ ${#VERSIONS[@]} -eq 0 ]; then
    error "No versions specified"
    usage
    exit 1
fi

# Check container engine
eng_init || exit 1
IMAGE_NAME=$(eng_qualify "$IMAGE_NAME")

# Build
log "Building PHP images: ${VERSIONS[*]}"
log "Image name: ${IMAGE_NAME}   Engine: ${ENGINE}"
echo "========================================"

for version in "${VERSIONS[@]}"; do
    TOTAL=$((TOTAL + 1))
    build_image "$version" || true
    echo "----------------------------------------"
done

# Statistics
echo "========================================"
log "Build completed"
log "Total: ${TOTAL}, Success: ${SUCCESSFUL}, Failed: ${FAILED}"

if [ $FAILED -gt 0 ]; then
    exit 1
fi
