#!/bin/bash

set -e

# Проверяет, вышли ли новые патчи (или пересобралась база без бампа патча —
# напр. security-фикс в Debian) у php:X.Y-fpm, и если да — добирает ВСЕ
# пропущенные патчи от последнего собранного этой машиной до текущей головы
# ветки (не только последний), пушит каждый как X.Y.Z-<arch>, а для самого
# нового из добранных ещё и двигает движущийся X.Y-<arch>. В конце зовёт
# stitch.sh, чтобы обновить мультиарх-манифесты X.Y.Z и X.Y.
#
# Список патчей и их дайджесты берутся через публичный Hub API
# (hub.docker.com, без токена) — там сразу видно и версии, и то, что
# конкретно изменилось, без скачивания образов.
#
# Состояние (последняя версия + её дайджест, собранные ЭТОЙ машиной под ЕЁ
# архитектурой) — в STATE_FILE. Обновляется по одной версии за раз, СРАЗУ
# после успешного пуша — если сборка где-то в середине диапазона упала,
# следующий прогон продолжит именно с неё, а не с начала.
#
# Первый раз для новой ветки (нет записи в state): либо --seed (запомнить
# текущую голову и ничего не собирать), либо без --seed — соберёт только
# текущую голову (не всю историю; для истории — backfill.sh руками).
#
# Архитектура берётся у движка (docker/podman, см. engine.sh) — machine-local,
# ничего передавать не нужно. Мультиарх-склейка требует architectures.conf.
#
# Ночной прогон повешен на пользовательский таймер php-check-updates.timer
# (03:00 Asia/Almaty). Логи — в journalctl --user -u php-check-updates.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MINORS=(8.2 8.3 8.4 8.5)          # какие ветки отслеживаем (можно переопределить аргументами)
STATE_FILE="$SCRIPT_DIR/.build-state"
HUB_REPO="library/php"            # официальный образ php на Docker Hub
SEED=false

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()     { echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }

source "$SCRIPT_DIR/engine.sh"

usage() {
    echo "Usage: $0 [--seed] [MINOR...]"
    echo ""
    echo "  --seed       Только запомнить текущую голову ветки, не собирать (для первого запуска)"
    echo "  MINOR...     Ветки для проверки (по умолчанию: ${MINORS[*]})"
    echo ""
    echo "  $0 --seed              # инициализация состояния"
    echo "  $0                     # проверить все ветки и добрать пропущенные патчи"
    echo "  $0 8.4 8.5             # проверить только 8.4 и 8.5"
}

ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        --seed)   SEED=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*)       error "Unknown option: $1"; usage; exit 1 ;;
        *)        ARGS+=("$1"); shift ;;
    esac
done
[ ${#ARGS[@]} -gt 0 ] && MINORS=("${ARGS[@]}")

command -v curl    &>/dev/null || { error "curl не установлен"; exit 1; }
command -v python3 &>/dev/null || { error "python3 не установлен"; exit 1; }

eng_init || exit 1

ARCH=$(eng_arch)
[ -z "$ARCH" ] && { error "Не смогла определить архитектуру у ${ENGINE}"; exit 1; }

# Список X.Y.Z-fpm патчей минорной ветки с дайджестами, отсортирован по версии.
# Печатает строки "версия дайджест".
fetch_patches() {
    local minor=$1
    curl -fsS "https://hub.docker.com/v2/repositories/${HUB_REPO}/tags/?name=${minor}&page_size=100" \
    | python3 -c "
import sys, json, re
minor = '${minor}'
pat = re.compile(r'^' + re.escape(minor) + r'\.[0-9]+-fpm\$')
d = json.load(sys.stdin)
rows = []
for r in d['results']:
    if pat.match(r['name']):
        rows.append((r['name'][:-4], r['digest']))
rows.sort(key=lambda t: tuple(int(x) for x in t[0].split('.')))
for ver, dig in rows:
    print(ver, dig)
"
}

declare -A STATE_VER STATE_DIGEST
if [ -f "$STATE_FILE" ]; then
    while read -r m v d; do
        [ -n "$m" ] && { STATE_VER["$m"]="$v"; STATE_DIGEST["$m"]="$d"; }
    done < "$STATE_FILE"
fi

save_state() {
    local tmp="${STATE_FILE}.tmp"
    : > "$tmp"
    for m in "${!STATE_VER[@]}"; do
        echo "$m ${STATE_VER[$m]} ${STATE_DIGEST[$m]}"
    done | sort -V > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

# true, если версия $1 > версия $2 (X.Y.Z по числам)
ver_gt() {
    python3 -c "
import sys
a = tuple(int(x) for x in '$1'.split('.'))
b = tuple(int(x) for x in '$2'.split('.'))
sys.exit(0 if a > b else 1)
"
}

CHANGED=0; REBUILT=0; FAILED=0

log "Проверяю (engine=$ENGINE, arch=$ARCH): ${MINORS[*]}  (seed=${SEED})"
echo "========================================"

for minor in "${MINORS[@]}"; do
    mapfile -t patches < <(fetch_patches "$minor")
    if [ ${#patches[@]} -eq 0 ]; then
        error "$minor: не нашла ни одного X.Y.Z-fpm тега на Hub"; FAILED=$((FAILED+1)); continue
    fi

    latest_line="${patches[-1]}"
    latest_ver="${latest_line%% *}"
    latest_dig="${latest_line#* }"

    old_ver="${STATE_VER[$minor]:-}"
    old_dig="${STATE_DIGEST[$minor]:-}"

    if [ "$SEED" = true ]; then
        STATE_VER[$minor]="$latest_ver"; STATE_DIGEST[$minor]="$latest_dig"
        log "$minor: запомнила $latest_ver ($latest_dig)"
        continue
    fi

    if [ "$latest_ver" = "$old_ver" ] && [ "$latest_dig" = "$old_dig" ]; then
        log "$minor: без изменений ($old_ver)"
        continue
    fi

    # Диапазон версий строго новее уже собранной (по числовому сравнению)
    missing=()
    for line in "${patches[@]}"; do
        v="${line%% *}"
        if [ -z "$old_ver" ] || ver_gt "$v" "$old_ver"; then
            missing+=("$line")
        fi
    done

    if [ ${#missing[@]} -eq 0 ]; then
        # Версия та же (old_ver == latest_ver), но дайджест другой —
        # пересборка базы без бампа патча (напр. security-фикс в Debian)
        missing=("$latest_line")
        log "$minor: патч тот же ($latest_ver), но база пересобралась — форс-ребилд"
    elif [ -z "$old_ver" ]; then
        warning "$minor: нет записи состояния — соберу только голову ($latest_ver), не всю историю"
        missing=("$latest_line")
    fi

    CHANGED=$((CHANGED+1))
    log "$minor: нужно собрать ${#missing[@]} версии(й): ${missing[*]%% *}"

    minor_failed=0
    for i in "${!missing[@]}"; do
        v="${missing[$i]%% *}"
        d="${missing[$i]#* }"
        is_last=false
        [ "$i" -eq $((${#missing[@]}-1)) ] && is_last=true

        flags=(--stitch)
        [ "$is_last" = true ] && flags+=(--set-moving)

        log "$minor: собираю $v ${flags[*]}"
        if ./backfill.sh "${flags[@]}" "$v"; then
            STATE_VER[$minor]="$v"; STATE_DIGEST[$minor]="$d"
            save_state
            REBUILT=$((REBUILT+1))
            success "$minor: $v собран и запушен"
        else
            error "$minor: сборка $v упала — останавливаюсь на этой ветке, дальше по диапазону не иду"
            minor_failed=1
            break
        fi
    done
    [ "$minor_failed" -eq 1 ] && FAILED=$((FAILED+1))
    echo "----------------------------------------"
done

save_state

echo "========================================"
if [ "$SEED" = true ]; then
    log "Seed готов: состояние в $STATE_FILE"
else
    log "Изменилось веток: ${CHANGED}, версий собрано: ${REBUILT}, ошибок: ${FAILED}"
fi

[ $FAILED -gt 0 ] && exit 1 || exit 0
