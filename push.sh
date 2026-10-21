#!/bin/bash

set -e

# Пушит образы, собранные build.sh, под тегами с суффиксом архитектуры
# (X.Y-<arch>, X.Y-latest-<arch>, X.Y.Z-<arch>) — голые теги (X.Y, X.Y.Z)
# оставляет как есть, их пишет только stitch.sh, иначе один push с одной
# архитектуры перезатрёт мультиарх-манифест single-arch образом.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="winterhearted/php-fpm"
ARCH=""
STITCH=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

source "$SCRIPT_DIR/engine.sh"

# Варианты образа — это php-X.Y/Dockerfile.<variant>. Теги варианта — базовые с
# суффиксом перед архитектурой: X.Y-vips-<arch>, X.Y-latest-vips-<arch>.
list_variants() {
    local php_dir=$1 f
    for f in "$php_dir"/Dockerfile.*; do
        [ -f "$f" ] || continue
        echo "${f##*/Dockerfile.}"
    done
}

# All available PHP versions
ALL_VERSIONS=(5.3 5.4 5.5 5.6 7.0 7.1 7.2 7.3 7.4 8.0 8.1 8.2 8.3 8.4 8.5)

# Counters
TOTAL=0
SUCCESSFUL=0
FAILED=0

usage() {
    echo "Usage: $0 [OPTIONS] [VERSIONS...]"
    echo ""
    echo "Push PHP-FPM Docker images to registry under arch-suffixed tags."
    echo ""
    echo "Options:"
    echo "  -n, --name NAME    Base image name (default: winterhearted/php-fpm)"
    echo "  -a, --arch ARCH    Arch suffix (default: движок сам скажет свою)"
    echo "  --all              Push all available versions"
    echo "  --stitch           После пуша вызвать stitch.sh для каждой версии (склеить мультиарх)"
    echo "  -h, --help         Show this help"
    echo ""
    echo "Available versions: ${ALL_VERSIONS[*]}"
    echo ""
    echo "Examples:"
    echo "  $0 8.3 8.4              Push PHP 8.3 and 8.4"
    echo "  $0 --stitch 8.4         Push and immediately stitch multi-arch manifest"
    echo "  $0 -n mycompany/php 8.3 Push with custom image name"
}

push_image() {
    local version=$1
    local version_tag="${IMAGE_NAME}:${version}"
    local latest_tag="${IMAGE_NAME}:${version}-latest"
    local version_arch_tag="${IMAGE_NAME}:${version}-${ARCH}"
    local latest_arch_tag="${IMAGE_NAME}:${version}-latest-${ARCH}"

    log "Pushing ${version_arch_tag}"

    # Check if image exists
    if ! eng image inspect "$version_tag" &> /dev/null; then
        error "Image $version_tag not found. Build it first."
        return 1
    fi

    eng tag "$version_tag" "$version_arch_tag"
    eng tag "$version_tag" "$latest_arch_tag"

    # Get exact version tag if exists
    local exact_version
    exact_version=$(eng run --rm "$version_tag" php -r 'echo PHP_VERSION;' 2>/dev/null || true)
    local exact_arch_tag=""
    if [ -n "$exact_version" ]; then
        exact_arch_tag="${IMAGE_NAME}:${exact_version}-${ARCH}"
        eng tag "$version_tag" "$exact_arch_tag"
    fi

    local push_failed=0

    eng push "$version_arch_tag" || push_failed=1
    eng push "$latest_arch_tag" || push_failed=1
    [ -n "$exact_arch_tag" ] && { eng push "$exact_arch_tag" || push_failed=1; }

    local variants=() variant
    for variant in $(list_variants "php-${version}"); do
        if ! eng image inspect "${version_tag}-${variant}" &> /dev/null; then
            warning "Образ ${version_tag}-${variant} не собран, пропускаю вариант"
            continue
        fi
        variants+=("$variant")
        eng tag "${version_tag}-${variant}" "${IMAGE_NAME}:${version}-${variant}-${ARCH}"
        eng tag "${version_tag}-${variant}" "${IMAGE_NAME}:${version}-latest-${variant}-${ARCH}"
        eng push "${IMAGE_NAME}:${version}-${variant}-${ARCH}" || push_failed=1
        eng push "${IMAGE_NAME}:${version}-latest-${variant}-${ARCH}" || push_failed=1
        if [ -n "$exact_version" ]; then
            eng tag "${version_tag}-${variant}" "${IMAGE_NAME}:${exact_version}-${variant}-${ARCH}"
            eng push "${IMAGE_NAME}:${exact_version}-${variant}-${ARCH}" || push_failed=1
        fi
    done

    if [ $push_failed -eq 0 ]; then
        success "Pushed: $version_arch_tag${exact_version:+ ($exact_version)}${variants:+ + варианты: ${variants[*]}}"
        SUCCESSFUL=$((SUCCESSFUL + 1))

        # Всё запушено — локальные копии больше не нужны (stitch работает по реестру)
        local cleanup_refs=("$version_tag")
        for variant in "${variants[@]}"; do cleanup_refs+=("${version_tag}-${variant}"); done
        eng_cleanup "${cleanup_refs[@]}"
        log "Локальные образы ${version} удалены"
    else
        error "Failed to push $version_arch_tag"
        FAILED=$((FAILED + 1))
        return 1
    fi

    if [ "$STITCH" = true ]; then
        local stitch_versions=("$version")
        [ -n "$exact_version" ] && stitch_versions+=("$exact_version")
        for variant in "${variants[@]}"; do
            stitch_versions+=("${version}-${variant}")
            [ -n "$exact_version" ] && stitch_versions+=("${exact_version}-${variant}")
        done
        if ! ./stitch.sh "${stitch_versions[@]}"; then
            error "stitch.sh упал для: ${stitch_versions[*]}"
            FAILED=$((FAILED + 1))
            return 1
        fi
    fi
}

# Defaults
VERSIONS=()

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)
            IMAGE_NAME="$2"
            shift 2
            ;;
        -a|--arch)
            ARCH="$2"
            shift 2
            ;;
        --all)
            VERSIONS=("${ALL_VERSIONS[@]}")
            shift
            ;;
        --stitch)
            STITCH=true
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

# Validate
if [ ${#VERSIONS[@]} -eq 0 ]; then
    error "No versions specified"
    usage
    exit 1
fi

# Check container engine
eng_init || exit 1
IMAGE_NAME=$(eng_qualify "$IMAGE_NAME")

if [ -z "$ARCH" ]; then
    ARCH=$(eng_arch)
    [ -z "$ARCH" ] && { error "Не смогла определить архитектуру, задай -a/--arch явно"; exit 1; }
fi

# Push
log "Pushing PHP images: ${VERSIONS[*]}"
log "Image name: ${IMAGE_NAME}   Arch: ${ARCH}   Engine: ${ENGINE}   Stitch: ${STITCH}"
echo "========================================"

for version in "${VERSIONS[@]}"; do
    TOTAL=$((TOTAL + 1))
    push_image "$version" || true
    echo "----------------------------------------"
done

# Statistics
echo "========================================"
log "Push completed"
log "Total: ${TOTAL}, Success: ${SUCCESSFUL}, Failed: ${FAILED}"

if [ $FAILED -gt 0 ]; then
    exit 1
fi
