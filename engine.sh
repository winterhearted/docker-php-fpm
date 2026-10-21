#!/bin/bash

# Слой над контейнерным движком: на одноплатниках стоит docker, на VPS —
# rootless podman. Скрипты сборки держим одинаковыми на всех машинах (см.
# комментарий в architectures.conf), движок выбирается здесь на месте.
#
# Подключать после того, как в скрипте определены log/error/warning:
#   source "$SCRIPT_DIR/engine.sh"
#   eng_init || exit 1
#
# Наружу:
#   ENGINE                  docker | podman
#   eng ...                 вызов движка (build/run/tag/push/image inspect — совместимы)
#   eng_init                выбрать движок; печатает причину и возвращает 1, если нечего выбрать
#   eng_arch                суффикс архитектуры: amd64 | arm64 | riscv64
#   eng_qualify NAME        имя образа, пригодное для пуша этим движком
#   eng_remote_exists REF   есть ли такой тег в реестре
#   eng_stitch "TAGS" REFS  склеить мультиарх-манифест и запушить под каждым тегом
#   eng_cleanup REF...      удалить локальные образы после пуша и подчистить кеш сборки

ENGINE="${ENGINE:-}"

eng_init() {
    # Явный выбор через переменную окружения — для отладки и для машин,
    # где стоят оба движка сразу.
    if [ -n "$ENGINE" ]; then
        command -v "$ENGINE" &>/dev/null || { echo "[ERROR] ENGINE=$ENGINE не найден" >&2; return 1; }
        "$ENGINE" info &>/dev/null || { echo "[ERROR] $ENGINE не отвечает (демон не запущен?)" >&2; return 1; }
        return 0
    fi

    if command -v docker &>/dev/null && docker info &>/dev/null; then
        ENGINE=docker
    elif command -v podman &>/dev/null && podman info &>/dev/null; then
        ENGINE=podman
    else
        echo "[ERROR] Не нашла рабочий docker или podman" >&2
        return 1
    fi
    return 0
}

eng() { "$ENGINE" "$@"; }

eng_arch() {
    case "$ENGINE" in
        docker) docker version --format '{{.Server.Arch}}' 2>/dev/null ;;
        # у podman нет .Server.Arch, только .Server.OsArch вида "linux/amd64"
        podman) podman version --format '{{.Server.OsArch}}' 2>/dev/null | cut -d/ -f2 ;;
    esac
}

# podman не разворачивает короткие имена без интерактивного выбора реестра,
# поэтому под ним дописываем docker.io/ всему, что ещё не указывает на реестр.
eng_qualify() {
    local name=$1
    if [ "$ENGINE" = podman ] \
       && [[ "$name" != */*/* ]] \
       && [[ "${name%%/*}" != *.* ]] \
       && [[ "${name%%/*}" != localhost ]]; then
        name="docker.io/${name}"
    fi
    echo "$name"
}

eng_remote_exists() {
    case "$ENGINE" in
        docker) docker buildx imagetools inspect "$1" &>/dev/null ;;
        # podman manifest inspect не годится: на одиночном манифесте он падает
        # с "Treating single images as manifest lists is not implemented", а
        # podman пушит арх-теги именно такими — в отличие от buildx, который
        # делает OCI-индексы. Поэтому пробуем добавить тег в черновой список:
        # тот же вызов, что и в eng_stitch, одинаково ест и манифест, и индекс,
        # блобы при этом не тянет.
        podman)
            local list="localhost/php-probe-$$-$RANDOM"
            local rc=0
            podman manifest rm "$list" &>/dev/null || true
            podman manifest create "$list" &>/dev/null || return 1
            podman manifest add --all "$list" "$1" &>/dev/null || rc=1
            podman manifest rm "$list" &>/dev/null || true
            return $rc
            ;;
    esac
}

# eng_stitch "tag1 [tag2...]" ref1 [ref2...]
eng_stitch() {
    local tags_str=$1; shift
    local -a tags refs
    read -r -a tags <<< "$tags_str"
    refs=("$@")

    if [ "$ENGINE" = docker ]; then
        local args=()
        local t
        for t in "${tags[@]}"; do args+=(-t "$t"); done
        docker buildx imagetools create "${args[@]}" "${refs[@]}"
        return $?
    fi

    # podman: собираем локальный список из удалённых ссылок и пушим его под
    # каждым тегом. --all обязателен: арх-теги от buildx — это OCI-индексы
    # (образ + attestation), без него podman пытается выбрать инстанс под
    # архитектуру хоста и падает на чужих архитектурах.
    local list="localhost/php-stitch-$$"
    podman manifest rm "$list" &>/dev/null || true
    podman manifest create "$list" >/dev/null || return 1

    local rc=0 r t
    for r in "${refs[@]}"; do
        podman manifest add --all "$list" "$r" >/dev/null || { rc=1; break; }
    done
    if [ $rc -eq 0 ]; then
        for t in "${tags[@]}"; do
            podman manifest push --all "$list" "docker://$t" || { rc=1; break; }
        done
    fi

    podman manifest rm "$list" &>/dev/null || true
    return $rc
}

# eng_cleanup REF [REF...]
# Удалить уже запушенные локальные образы (со всеми их тегами) и то, что от их
# сборки осталось в кеше. Всё лежит на Hub, а сборки идут с --no-cache --pull,
# так что локальные копии ни для чего не нужны — без этого образы и кеш
# копились, пока не забили диск. Чистим только своё: образы по переданным
# ссылкам и висячие остатки; чужие образы и живой кеш не трогаем.
eng_cleanup() {
    local ids=() r id
    for r in "$@"; do
        id=$(eng image inspect --format '{{.Id}}' "$r" 2>/dev/null) && ids+=("$id")
    done
    [ ${#ids[@]} -eq 0 ] && return 0

    # -f: у образа пачка тегов (X.Y.Z, X.Y.Z-<arch>, X.Y-<arch>...), без него
    # rmi по ID откажется
    eng rmi -f $(printf '%s\n' "${ids[@]}" | sort -u) >/dev/null 2>&1 || true
    eng image prune -f >/dev/null 2>&1 || true
    # У docker слои ещё и в кеше BuildKit: после rmi он становится висячим, и
    # prune без -a снимает как раз его. У podman отдельного кеша нет —
    # промежуточные слои там висячие образы, их убрал image prune.
    if [ "$ENGINE" = docker ]; then
        docker builder prune -f >/dev/null 2>&1 || true
    fi
    return 0
}
