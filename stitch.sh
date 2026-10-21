#!/bin/bash

set -e

# Склеивает per-arch теги (X.Y.Z-<arch> или X.Y-<arch>) в один мультиарх-тег.
# Ничего не билдит и не пуллит образы целиком — работает по registry API
# (buildx imagetools под docker, podman manifest под podman, см. engine.sh).
#
# Идемпотентно: список арх-тегов читается заново при каждом вызове и манифест
# перезаписывается целиком, поэтому параллельные/повторные запуски с разных
# машин безопасны — это не read-modify-write состояния, а чистый пересчёт
# "какие арх-теги сейчас есть в реестре" -> "манифест-лист". Гонок нет, потому
# что каждая машина пишет только свои собственные X.Y[.Z]-<arch> (см.
# push.sh/backfill.sh), а сюда — только читает.
#
# X.Y (минорный, движущийся) склеивается leading-edge: берётся ПОСЛЕДНИЙ
# X.Y-<arch> от каждой архитектуры, даже если патчи временно разошлись между
# архитектурами (riscv64 почти всегда будет отставать — не блокируем amd64/
# arm64 в ожидании).
#
# X.Y.Z (точный патч) склеивается только из тех архитектур, что реально
# собрали именно этот патч — со временем "дозаклеивается", когда отстающая
# архитектура его наконец соберёт.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="winterhearted/php-fpm"
ARCH_FILE="$SCRIPT_DIR/architectures.conf"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

source "$SCRIPT_DIR/engine.sh"

usage() {
    echo "Usage: $0 [-n NAME] [--no-latest] VERSION [VERSION...]"
    echo ""
    echo "  VERSION      X.Y (минорный, движущийся тег + -latest) или X.Y.Z (точный патч),"
    echo "               с необязательным суффиксом варианта: X.Y-vips, X.Y.Z-vips"
    echo "  -n, --name   Base image name (default: winterhearted/php-fpm)"
    echo "  --no-latest  Не создавать алиас X.Y-latest (для пререлизных тегов)"
    echo ""
    echo "Examples:"
    echo "  $0 8.4              # склеить движущийся тег 8.4 / 8.4-latest"
    echo "  $0 8.4.23           # склеить точный тег 8.4.23"
    echo "  $0 8.3 8.3.32       # оба сразу"
    echo "  $0 8.3-vips         # вариант: 8.3-vips / 8.3-latest-vips"
    echo "  $0 --no-latest 8.6-rc   # только 8.6-rc, без алиаса 8.6-latest-rc"
}

VERSIONS=()
NO_LATEST=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name) IMAGE_NAME="$2"; shift 2 ;;
        --no-latest) NO_LATEST=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*)        error "Unknown option: $1"; usage; exit 1 ;;
        *)         VERSIONS+=("$1"); shift ;;
    esac
done

[ ${#VERSIONS[@]} -eq 0 ] && { error "No version specified"; usage; exit 1; }
[ -f "$ARCH_FILE" ] || { error "Не найден $ARCH_FILE"; exit 1; }

eng_init || exit 1
IMAGE_NAME=$(eng_qualify "$IMAGE_NAME")

if [ "$ENGINE" = docker ]; then
    docker buildx version &>/dev/null || { error "docker buildx недоступен"; exit 1; }
fi

mapfile -t ARCHES < <(grep -vE '^\s*(#|$)' "$ARCH_FILE" | tr -d ' \t\r')
[ ${#ARCHES[@]} -eq 0 ] && { error "$ARCH_FILE пуст"; exit 1; }

stitch_one() {
    local version=$1
    local refs=()

    log "Проверяю арх-теги для ${version}: ${ARCHES[*]}"
    for arch in "${ARCHES[@]}"; do
        local ref="${IMAGE_NAME}:${version}-${arch}"
        if eng_remote_exists "$ref"; then
            refs+=("$ref")
        else
            warning "  $ref не найден, пропускаю"
        fi
    done

    if [ ${#refs[@]} -eq 0 ]; then
        error "$version: ни один арх-тег не найден, склеивать нечего"
        return 1
    fi

    # X.Y[.Z] или X.Y[.Z]-<variant> (напр. 8.3-vips). Суффикс -latest вставляется
    # ПЕРЕД вариантом, чтобы теги читались одинаково: 8.3-latest, 8.3-latest-vips.
    local base="$version" variant=""
    if [[ "$version" =~ ^([0-9]+\.[0-9]+(\.[0-9]+)?)-(.+)$ ]]; then
        base="${BASH_REMATCH[1]}"
        variant="${BASH_REMATCH[3]}"
    fi

    local tags="${IMAGE_NAME}:${version}"
    if [ "$NO_LATEST" = false ] && [[ "$base" =~ ^[0-9]+\.[0-9]+$ ]]; then
        tags="$tags ${IMAGE_NAME}:${base}-latest${variant:+-$variant}"
    fi

    log "Склеиваю ${version} из: ${refs[*]}"
    if eng_stitch "$tags" "${refs[@]}"; then
        success "$version: склеено (${#refs[@]}/${#ARCHES[@]} архитектур: ${refs[*]##*-})"
    else
        error "$version: склейка мультиарх-манифеста упала"
        return 1
    fi
}

FAILED=0
for v in "${VERSIONS[@]}"; do
    stitch_one "$v" || FAILED=$((FAILED+1))
    echo "----------------------------------------"
done

[ $FAILED -gt 0 ] && exit 1 || exit 0
