#!/bin/bash

set -e

# Проверяет, вышли ли новые патчи (или пересобралась база без бампа патча —
# напр. security-фикс в Debian) у php:X.Y-fpm, и добирает ВСЕ пропущенные
# патчи от последнего собранного до текущей головы ветки (не только
# последний). Каждый пушится как X.Y.Z-<arch>, самый новый ещё и двигает
# X.Y-<arch>, в конце stitch.sh обновляет мультиарх-манифесты.
#
# Своего состояния у скрипта нет — всё берётся из реестров через hub.py:
#   * что вышло: теги php:X.Y.Z-fpm и дайджест их манифеста под нашу арх;
#   * что собрано: старший X.Y.Z-<arch> в winterhearted/php-fpm;
#   * из какой базы собрано: лейбл с дайджестом базы на этом теге (его ставит
#     backfill.sh). Нет лейбла или он не совпал — голову пересобираем.
# Поэтому машине или раннеру ничего не нужно помнить между запусками, а упавшая
# посреди диапазона сборка просто продолжится со следующего прогона.
#
# Два режима:
#   без --plan  собрать на этой машине под её архитектуру (самохостинг);
#   --plan      ничего не собирать, только напечатать план для GitHub Actions:
#               строки "ARCH VERSION DIGEST MOVING" (MOVING=1 — двигать X.Y),
#               архитектуры задаются --arch, логи идут в stderr.
#
# Первый раз для ветки или архитектуры (своих тегов ещё нет) собирается только
# текущая голова, не вся история — историю добирают backfill.sh руками.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MINORS=(8.2 8.3 8.4 8.5)          # какие ветки отслеживаем (можно переопределить аргументами)
IMAGE_NAME="winterhearted/php-fpm"
BASE_DIGEST_LABEL="org.opencontainers.image.base.digest"   # см. backfill.sh
PLAN=false
ARCHES=()

# stdout в режиме --plan занят планом, поэтому все логи — в stderr
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1" >&2; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1" >&2; }

source "$SCRIPT_DIR/engine.sh"

usage() {
    echo "Usage: $0 [--plan [--arch ARCH]...] [MINOR...]"
    echo ""
    echo "  --plan       Не собирать, напечатать план: ARCH VERSION DIGEST MOVING"
    echo "  --arch ARCH  Для --plan: под какие архитектуры планировать (можно несколько;"
    echo "               по умолчанию — архитектура движка)"
    echo "  MINOR...     Ветки для проверки (по умолчанию: ${MINORS[*]})"
    echo ""
    echo "  $0                                  # проверить все ветки и добрать пропущенные патчи"
    echo "  $0 8.4 8.5                          # проверить только 8.4 и 8.5"
    echo "  $0 --plan --arch amd64 --arch arm64 # план для CI"
}

ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --plan)    PLAN=true; shift ;;
        --arch)    ARCHES+=("$2"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*)        error "Unknown option: $1"; usage >&2; exit 1 ;;
        *)         ARGS+=("$1"); shift ;;
    esac
done
[ ${#ARGS[@]} -gt 0 ] && MINORS=("${ARGS[@]}")

command -v curl    &>/dev/null || { error "curl не установлен"; exit 1; }
command -v python3 &>/dev/null || { error "python3 не установлен"; exit 1; }

eng_init || exit 1

if [ ${#ARCHES[@]} -eq 0 ]; then
    ARCHES=("$(eng_arch)")
    [ -z "${ARCHES[0]}" ] && { error "Не смогла определить архитектуру у ${ENGINE}"; exit 1; }
elif [ "$PLAN" = false ]; then
    # собирать можно только своё, чужие архитектуры — только планировать
    error "--arch имеет смысл только с --plan"; exit 1
fi

# true, если версия $1 > версия $2 (X.Y.Z по числам)
ver_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# Печатает, что собрать для ветки под архитектуру: строки "VERSION DIGEST MOVING".
# UPSTREAM — вывод "hub.py upstream" для этой ветки: его листание медленное,
# поэтому тянем один раз на ветку, а не на каждую архитектуру.
plan_one() {
    local minor=$1 arch=$2
    local patches built line v

    mapfile -t patches < <(awk -v a="$arch" '$2 == a {print $1, $3}' <<< "$UPSTREAM")
    if [ ${#patches[@]} -eq 0 ]; then
        error "$minor/$arch: не нашла ни одного X.Y.Z-fpm тега с $arch на Hub"
        return 1
    fi
    local head_ver="${patches[-1]%% *}" head_dig="${patches[-1]#* }"

    if ! built=$(./hub.py ours "$IMAGE_NAME" "$minor" "$arch"); then
        error "$minor/$arch: не смогла получить наши теги с Hub"
        return 1
    fi

    if [ -z "$built" ]; then
        warning "$minor/$arch: своих тегов нет — соберу только голову ($head_ver), не всю историю"
        echo "$head_ver $head_dig 1"
        return 0
    fi

    if [ "$built" = "$head_ver" ]; then
        local have
        have=$(eng_remote_label "$(eng_qualify "$IMAGE_NAME"):${built}-${arch}" "$arch" "$BASE_DIGEST_LABEL" || true)
        if [ "$have" = "$head_dig" ]; then
            log "$minor/$arch: без изменений ($built)"
        else
            log "$minor/$arch: патч тот же ($built), но база ${have:+пересобралась}${have:-без лейбла} — форс-ребилд"
            echo "$head_ver $head_dig 1"
        fi
        return 0
    fi

    local missing=()
    for line in "${patches[@]}"; do
        v="${line%% *}"
        ver_gt "$v" "$built" && missing+=("$line")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        # наш новее головы upstream — значит, upstream откатил тег; не трогаем
        warning "$minor/$arch: собрано $built, а на Hub голова $head_ver — пропускаю"
        return 0
    fi

    log "$minor/$arch: собрано $built, нужно ещё ${#missing[@]}: ${missing[*]%% *}"
    local i
    for i in "${!missing[@]}"; do
        echo "${missing[$i]} $([ "$i" -eq $((${#missing[@]}-1)) ] && echo 1 || echo 0)"
    done
}

FAILED=0

log "Проверяю (engine=$ENGINE, arch=${ARCHES[*]}, plan=$PLAN): ${MINORS[*]}"

if [ "$PLAN" = true ]; then
    for minor in "${MINORS[@]}"; do
        UPSTREAM=$(./hub.py upstream "$minor") || UPSTREAM=""
        for arch in "${ARCHES[@]}"; do
            plan=$(plan_one "$minor" "$arch") || { FAILED=$((FAILED+1)); continue; }
            [ -n "$plan" ] && sed "s/^/$arch /" <<< "$plan"
        done
    done
    [ $FAILED -gt 0 ] && exit 1 || exit 0
fi

ARCH="${ARCHES[0]}"
CHANGED=0; REBUILT=0
echo "========================================" >&2

for minor in "${MINORS[@]}"; do
    UPSTREAM=$(./hub.py upstream "$minor") || UPSTREAM=""
    plan=$(plan_one "$minor" "$ARCH") || { FAILED=$((FAILED+1)); continue; }
    [ -z "$plan" ] && continue
    CHANGED=$((CHANGED+1))

    while read -r v d moving; do
        flags=(--stitch)
        [ "$moving" = 1 ] && flags+=(--set-moving)
        log "$minor: собираю $v ${flags[*]}"
        # </dev/null: иначе сборка съест остаток плана из stdin цикла
        if ./backfill.sh "${flags[@]}" "$v@$d" </dev/null; then
            REBUILT=$((REBUILT+1))
            success "$minor: $v собран и запушен"
        else
            error "$minor: сборка $v упала — останавливаюсь на этой ветке, дальше по диапазону не иду"
            FAILED=$((FAILED+1))
            break
        fi
    done <<< "$plan"
    echo "----------------------------------------" >&2
done

echo "========================================" >&2
log "Изменилось веток: ${CHANGED}, версий собрано: ${REBUILT}, ошибок: ${FAILED}"

[ $FAILED -gt 0 ] && exit 1 || exit 0
