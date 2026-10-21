#!/bin/bash

set -e

# Собирает КОНКРЕТНЫЕ патч-версии PHP (X.Y.Z) из базы php:X.Y.Z-fpm и пушит
# точный тег X.Y.Z-<arch> (архитектура берётся из локального движка, если не
# задана явно через -a). Движущийся per-arch тег X.Y-<arch> НЕ трогает, если
# явно не попросили --set-moving. Нужно для добора исторических патчей "для
# чистоты" и для точечной сборки/теста конкретной версии.
#
# Тег без суффикса архитектуры (X.Y.Z, X.Y) пушит ТОЛЬКО stitch.sh — если
# запушить его отсюда напрямую, он перезатрёт мультиарх-манифест
# single-arch образом. См. architectures.conf и stitch.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="winterhearted/php-fpm"
DOCKERFILE_NAME="Dockerfile"
ARCH=""
SET_MOVING=false
STITCH=false
PUSH=true

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

# Варианты образа — это php-X.Y/Dockerfile.<variant>, собираемые поверх готового
# базового образа. Теги: X.Y.Z-<variant>-<arch>, X.Y-<variant>-<arch>,
# X.Y-latest-<variant>-<arch>. Нет файла — нет варианта.
list_variants() {
    local php_dir=$1 f
    for f in "$php_dir"/Dockerfile.*; do
        [ -f "$f" ] || continue
        echo "${f##*/Dockerfile.}"
    done
}

TOTAL=0
SUCCESSFUL=0
FAILED=0

usage() {
    echo "Usage: $0 [OPTIONS] VERSION [VERSION...]"
    echo ""
    echo "Build exact PHP patch versions and push the X.Y.Z-<arch> tag."
    echo ""
    echo "Options:"
    echo "  -n, --name NAME    Base image name (default: winterhearted/php-fpm)"
    echo "  -a, --arch ARCH    Arch suffix (default: движок сам скажет свою)"
    echo "  -b, --build-only   Build locally, do not push"
    echo "  --set-moving       После пуша точного тега сдвинуть X.Y-<arch>/X.Y-latest-<arch> на эту версию"
    echo "  --stitch           После пуша вызвать stitch.sh (для точной версии, и для минора если --set-moving)"
    echo "  -h, --help         Show this help"
    echo ""
    echo "Examples:"
    echo "  $0 8.4.18 8.4.19 8.4.20 8.4.21"
    echo "  $0 --build-only 8.5.3 8.5.4"
    echo "  $0 --set-moving --stitch 8.4.23     # догнать голову ветки и сразу опубликовать"
}

build_one() {
    local version=$1
    local minor="${version%.*}"          # 8.4.19 -> 8.4
    local php_dir="php-${minor}"
    local base_tag="${version}-fpm"       # php:8.4.19-fpm
    local exact_tag="${IMAGE_NAME}:${version}"
    local exact_arch_tag="${IMAGE_NAME}:${version}-${ARCH}"

    log "Building ${exact_arch_tag} from php:${base_tag}"

    if [ ! -f "$php_dir/$DOCKERFILE_NAME" ]; then
        error "File $php_dir/$DOCKERFILE_NAME not found"
        FAILED=$((FAILED + 1)); return 1
    fi

    # Без PHP_BASE в Dockerfile мы бы молча собрали не тот патч
    if ! grep -q 'ARG PHP_BASE' "$php_dir/$DOCKERFILE_NAME"; then
        error "$php_dir/$DOCKERFILE_NAME не поддерживает ARG PHP_BASE — добавь его"
        FAILED=$((FAILED + 1)); return 1
    fi

    if ! eng build --no-cache --pull \
            --build-arg "PHP_BASE=${base_tag}" \
            -t "$exact_tag" "$php_dir"; then
        error "Failed to build $exact_tag"
        FAILED=$((FAILED + 1)); return 1
    fi

    # Сверяем, что внутри именно запрошенный патч
    local built
    built=$(eng run --rm "$exact_tag" php -r 'echo PHP_VERSION;' 2>/dev/null || true)
    if [ "$built" != "$version" ]; then
        error "Version mismatch: requested $version, image has '${built:-unknown}'. Not pushing."
        FAILED=$((FAILED + 1)); return 1
    fi

    eng tag "$exact_tag" "$exact_arch_tag"

    # Варианты — поверх только что собранного локального образа, без --pull/--no-cache
    local variants=() variant
    for variant in $(list_variants "$php_dir"); do
        log "Building ${exact_tag}-${variant}"
        if ! eng build --build-arg "BASE_IMAGE=${exact_tag}" \
                -f "$php_dir/Dockerfile.${variant}" \
                -t "${exact_tag}-${variant}" "$php_dir"; then
            error "Failed to build ${exact_tag}-${variant}"
            FAILED=$((FAILED + 1)); return 1
        fi
        variants+=("$variant")
        eng tag "${exact_tag}-${variant}" "${IMAGE_NAME}:${version}-${variant}-${ARCH}"
    done

    if [ "$PUSH" = true ]; then
        if ! eng push "$exact_arch_tag"; then
            error "Failed to push $exact_arch_tag"
            FAILED=$((FAILED + 1)); return 1
        fi
        success "Pushed: $exact_arch_tag ($built)"

        for variant in "${variants[@]}"; do
            if ! eng push "${IMAGE_NAME}:${version}-${variant}-${ARCH}"; then
                error "Failed to push ${IMAGE_NAME}:${version}-${variant}-${ARCH}"
                FAILED=$((FAILED + 1)); return 1
            fi
            success "Pushed: ${IMAGE_NAME}:${version}-${variant}-${ARCH}"
        done

        if [ "$SET_MOVING" = true ]; then
            local moving_tag="${IMAGE_NAME}:${minor}-${ARCH}"
            local latest_tag="${IMAGE_NAME}:${minor}-latest-${ARCH}"
            eng tag "$exact_tag" "$moving_tag"
            eng tag "$exact_tag" "$latest_tag"
            if ! eng push "$moving_tag" || ! eng push "$latest_tag"; then
                error "Failed to push moving tags for $minor"
                FAILED=$((FAILED + 1)); return 1
            fi
            success "Pushed moving: $moving_tag, $latest_tag"

            for variant in "${variants[@]}"; do
                local vmoving="${IMAGE_NAME}:${minor}-${variant}-${ARCH}"
                local vlatest="${IMAGE_NAME}:${minor}-latest-${variant}-${ARCH}"
                eng tag "${exact_tag}-${variant}" "$vmoving"
                eng tag "${exact_tag}-${variant}" "$vlatest"
                if ! eng push "$vmoving" || ! eng push "$vlatest"; then
                    error "Failed to push moving tags for ${minor}-${variant}"
                    FAILED=$((FAILED + 1)); return 1
                fi
                success "Pushed moving: $vmoving, $vlatest"
            done
        fi

        # Всё запушено — локальные копии больше не нужны (stitch ниже работает
        # по реестру). При --build-only сюда не попадаем, образы остаются.
        local cleanup_refs=("$exact_tag")
        for variant in "${variants[@]}"; do cleanup_refs+=("${exact_tag}-${variant}"); done
        eng_cleanup "${cleanup_refs[@]}"
        log "Локальные образы ${version} удалены"

        if [ "$STITCH" = true ]; then
            local stitch_versions=("$version")
            [ "$SET_MOVING" = true ] && stitch_versions+=("$minor")
            for variant in "${variants[@]}"; do
                stitch_versions+=("${version}-${variant}")
                [ "$SET_MOVING" = true ] && stitch_versions+=("${minor}-${variant}")
            done
            if ! ./stitch.sh "${stitch_versions[@]}"; then
                error "stitch.sh упал для: ${stitch_versions[*]}"
                FAILED=$((FAILED + 1)); return 1
            fi
        fi
    else
        success "Built (not pushed): $exact_arch_tag ($built)"
    fi
    SUCCESSFUL=$((SUCCESSFUL + 1))
}

VERSIONS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)       IMAGE_NAME="$2"; shift 2 ;;
        -a|--arch)       ARCH="$2"; shift 2 ;;
        -b|--build-only) PUSH=false; shift ;;
        --set-moving)    SET_MOVING=true; shift ;;
        --stitch)        STITCH=true; shift ;;
        -h|--help)       usage; exit 0 ;;
        -*)              error "Unknown option: $1"; usage; exit 1 ;;
        *)               VERSIONS+=("$1"); shift ;;
    esac
done

if [ ${#VERSIONS[@]} -eq 0 ]; then
    error "No versions specified"; usage; exit 1
fi

# Валидация формата X.Y.Z
for v in "${VERSIONS[@]}"; do
    if ! [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "Invalid version '$v' (expected X.Y.Z, e.g. 8.4.19)"; exit 1
    fi
done

eng_init || exit 1
IMAGE_NAME=$(eng_qualify "$IMAGE_NAME")

if [ -z "$ARCH" ]; then
    ARCH=$(eng_arch)
    [ -z "$ARCH" ] && { error "Не смогла определить архитектуру, задай -a/--arch явно"; exit 1; }
fi

log "Backfill exact versions: ${VERSIONS[*]}"
log "Image name: ${IMAGE_NAME}   Arch: ${ARCH}   Engine: ${ENGINE}   Push: ${PUSH}   Set-moving: ${SET_MOVING}   Stitch: ${STITCH}"
echo "========================================"

for version in "${VERSIONS[@]}"; do
    TOTAL=$((TOTAL + 1))
    build_one "$version" || true
    echo "----------------------------------------"
done

echo "========================================"
log "Backfill completed"
log "Total: ${TOTAL}, Success: ${SUCCESSFUL}, Failed: ${FAILED}"

[ $FAILED -gt 0 ] && exit 1 || exit 0
