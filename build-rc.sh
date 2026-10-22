#!/bin/bash

set -e

# Пересобирает пререлизную ветку PHP (сейчас 8.6) из движущегося официального
# образа php:8.6-rc-fpm и публикует её под пререлизными тегами.
#
# Почему отдельный скрипт, а не check-updates.sh:
#   * у альф теги вида 8.6.0alpha3-fpm, а не X.Y.Z-fpm — регулярка
#     check-updates.sh их не видит и учить её этому незачем;
#   * вся логика "добери все пропущенные патчи по дайджестам" для альф
#     бессмысленна: промежуточные альфы никому не нужны, нужна текущая;
#   * тут не бывает "без изменений": пересобираем безусловно, потому что
#     набор фич ещё не заморожен и смысл в свежести, а не в экономии.
#
# Публикуемые теги (per-arch, склейка — stitch.sh):
#   8.6-rc            движущийся, всегда последняя альфа/RC
#   8.6-rc-YYYYMMDD   снимок на дату, чтобы можно было закрепиться и не ловить
#                     смену альфы посреди отладки
#   плюс -vips версии обоих.
#
# Чего этот скрипт НЕ делает намеренно: не трогает 8.6 и 8.6-latest. Они должны
# оставаться пустыми до релиза — иначе кто-нибудь притянет альфу, думая, что
# это стабильная ветка.
#
# Дата в теге — UTC, а не локальная. Все три машины ходят по таймеру в 03:00
# Алматы (= 21:00 UTC предыдущего дня), так что в UTC дата у них совпадает,
# и склейка находит соседей. По локальному времени машины в разных TZ дали бы
# разные теги и три однoархитектурных снимка вместо одного.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

IMAGE_NAME="winterhearted/php-fpm"
MINOR="8.6"
BASE_TAG="8.6-rc-fpm"     # движущийся официальный образ пререлиза
RC_TAG="8.6-rc"           # как это называется у нас
ARCH=""
PUSH=true
STITCH=true
DATE_STAMP=""

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

source "$SCRIPT_DIR/engine.sh"

# Варианты образа — php-X.Y/Dockerfile.<variant>, собираются поверх готового
# базового образа. Тот же механизм, что в build.sh/backfill.sh.
list_variants() {
    local php_dir=$1 f
    for f in "$php_dir"/Dockerfile.*; do
        [ -f "$f" ] || continue
        echo "${f##*/Dockerfile.}"
    done
}

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Пересобрать пререлизную ветку ${MINOR} из php:${BASE_TAG} и запушить"
    echo "${RC_TAG}-<arch> и ${RC_TAG}-<дата>-<arch> (плюс варианты)."
    echo ""
    echo "Options:"
    echo "  -n, --name NAME    Base image name (default: ${IMAGE_NAME})"
    echo "  -a, --arch ARCH    Arch suffix (default: движок сам скажет свою)"
    echo "  -b, --build-only   Собрать локально, не пушить (подразумевает --no-stitch)"
    echo "  --no-stitch        Не звать stitch.sh после пуша"
    echo "  --date YYYYMMDD    Дата для снимка (default: сегодня по UTC)"
    echo "  -h, --help         Show this help"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--name)       IMAGE_NAME="$2"; shift 2 ;;
        -a|--arch)       ARCH="$2"; shift 2 ;;
        -b|--build-only) PUSH=false; STITCH=false; shift ;;
        --no-stitch)     STITCH=false; shift ;;
        --date)          DATE_STAMP="$2"; shift 2 ;;
        -h|--help)       usage; exit 0 ;;
        *)               error "Unknown option: $1"; usage; exit 1 ;;
    esac
done

[ -n "$DATE_STAMP" ] || DATE_STAMP="$(date -u +%Y%m%d)"
if ! [[ "$DATE_STAMP" =~ ^[0-9]{8}$ ]]; then
    error "--date ожидает YYYYMMDD, получила '$DATE_STAMP'"; exit 1
fi

PHP_DIR="php-${MINOR}"
[ -d "$PHP_DIR" ] || { error "Нет каталога $PHP_DIR"; exit 1; }
[ -f "$PHP_DIR/Dockerfile" ] || { error "Нет $PHP_DIR/Dockerfile"; exit 1; }

eng_init || exit 1
IMAGE_NAME=$(eng_qualify "$IMAGE_NAME")

if [ -z "$ARCH" ]; then
    ARCH=$(eng_arch)
    [ -z "$ARCH" ] && { error "Не смогла определить архитектуру, задай -a/--arch явно"; exit 1; }
fi

LOCAL_TAG="${IMAGE_NAME}:${RC_TAG}"

log "Пререлиз ${MINOR}: собираю из php:${BASE_TAG}"
log "Engine: ${ENGINE}   Arch: ${ARCH}   Дата снимка: ${DATE_STAMP}   Push: ${PUSH}"
echo "========================================"

# --pull обязателен: базовый тег движущийся, локальная копия почти всегда устарела
if ! eng build --no-cache "$(eng_pull)" \
        --build-arg "PHP_BASE=${BASE_TAG}" \
        -t "$LOCAL_TAG" "$PHP_DIR"; then
    error "Сборка ${LOCAL_TAG} упала"
    exit 1
fi

BUILT=$(eng run --rm "$LOCAL_TAG" php -r 'echo PHP_VERSION;' 2>/dev/null || true)
# Тег 8.6-rc-fpm станет 8.7-rc-fpm, как только 8.6 зарелизят — тогда мы бы молча
# начали публиковать 8.7 под именем 8.6-rc. Лучше упасть и сходить поправить.
if [[ "$BUILT" != ${MINOR}.* ]]; then
    error "В образе '${BUILT:-unknown}', а ожидалась ветка ${MINOR}."
    error "Похоже, php:${BASE_TAG} уехал на следующую ветку — поправь MINOR/BASE_TAG."
    exit 1
fi
success "Собрано: ${BUILT}"

# Варианты — поверх только что собранного локального образа, без --pull/--no-cache
VARIANTS=()
for variant in $(list_variants "$PHP_DIR"); do
    log "Собираю вариант ${RC_TAG}-${variant}"
    if ! eng build --build-arg "BASE_IMAGE=${LOCAL_TAG}" \
            -f "$PHP_DIR/Dockerfile.${variant}" \
            -t "${LOCAL_TAG}-${variant}" "$PHP_DIR"; then
        error "Сборка варианта ${RC_TAG}-${variant} упала"
        exit 1
    fi
    VARIANTS+=("$variant")
    success "Собрано: ${RC_TAG}-${variant}"
done

if [ "$PUSH" != true ]; then
    log "Собрано локально, не пушу (--build-only)"
    exit 0
fi

# Что публикуем: пара (наш тег без арх-суффикса) -> локальный образ
declare -a STITCH_LIST=()
push_pair() {
    local tag=$1 src=$2
    eng tag "$src" "${IMAGE_NAME}:${tag}-${ARCH}"
    if ! eng push "${IMAGE_NAME}:${tag}-${ARCH}"; then
        error "Не смогла запушить ${IMAGE_NAME}:${tag}-${ARCH}"
        return 1
    fi
    success "Запушено: ${IMAGE_NAME}:${tag}-${ARCH}"
    STITCH_LIST+=("$tag")
}

push_pair "${RC_TAG}" "$LOCAL_TAG" || exit 1
push_pair "${RC_TAG}-${DATE_STAMP}" "$LOCAL_TAG" || exit 1

for variant in "${VARIANTS[@]}"; do
    push_pair "${RC_TAG}-${variant}" "${LOCAL_TAG}-${variant}" || exit 1
    push_pair "${RC_TAG}-${DATE_STAMP}-${variant}" "${LOCAL_TAG}-${variant}" || exit 1
done

# Всё запушено — локальные копии больше не нужны (stitch работает по реестру)
CLEANUP_REFS=("$LOCAL_TAG")
for variant in "${VARIANTS[@]}"; do CLEANUP_REFS+=("${LOCAL_TAG}-${variant}"); done
eng_cleanup "${CLEANUP_REFS[@]}"
log "Локальные образы ${RC_TAG} удалены"

if [ "$STITCH" = true ]; then
    # --no-latest: без него stitch разобрал бы 8.6-rc как "минор 8.6 + вариант rc"
    # и завёл алиас 8.6-latest-rc, которого мы не хотим
    log "Склеиваю: ${STITCH_LIST[*]}"
    if ! ./stitch.sh --no-latest "${STITCH_LIST[@]}"; then
        error "stitch.sh упал"
        exit 1
    fi
fi

echo "========================================"
success "Пререлиз ${MINOR} (${BUILT}) опубликован: ${RC_TAG}, ${RC_TAG}-${DATE_STAMP} и варианты"
