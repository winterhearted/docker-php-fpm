ARG PHP_BASE=8.4-fpm
# Рантайм-база. Должна совпадать с дистрибутивом внутри php:${PHP_BASE} —
# builder это проверяет и падает, если Debian уехал на следующий релиз.
ARG DEBIAN_SUITE=trixie

# ---------------------------------------------------------------------------
# builder: компиляция расширений. Ничего отсюда, кроме /usr/local и списка
# рантайм-зависимостей, в финальный образ не попадает.
# ---------------------------------------------------------------------------
FROM php:${PHP_BASE} AS builder
ARG DEBIAN_SUITE

RUN set -eux; \
    . /etc/os-release; \
    if [ "$VERSION_CODENAME" != "$DEBIAN_SUITE" ]; then \
        echo "php:${PHP_VERSION}-fpm собран на '$VERSION_CODENAME', а рантайм-стадия на '$DEBIAN_SUITE'." >&2; \
        echo "Поправь ARG DEBIAN_SUITE, иначе рантайм получит чужую glibc." >&2; \
        exit 1; \
    fi

# opcache и sodium уже собраны и включены в официальном образе — не трогаем.
# ffi собираем, но НЕ включаем: он нужен только варианту -vips (Dockerfile.vips).
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libzip-dev libjpeg62-turbo-dev libpng-dev libwebp-dev libavif-dev \
        libfreetype-dev zlib1g-dev libpq-dev libicu-dev libxml2-dev \
        libmagickwand-dev libmagickcore-dev libffi-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp --with-avif; \
    docker-php-ext-install -j"$(nproc)" \
        pdo pdo_mysql pdo_pgsql mysqli gd zip intl bcmath exif soap ffi; \
    pecl install imagick; \
    docker-php-ext-enable imagick; \
    rm -f /usr/local/etc/php/conf.d/docker-php-ext-ffi.ini

# Что из пакетов Debian реально нужно рантайму — считаем по ldd самих бинарников
# и собранных .so, а не списком руками: список руками гниёт на каждом релизе.
# realpath обязателен: ldd печатает merged-usr пути (/lib/...), а dpkg владеет
# /usr/lib/... — без канонизации dpkg-query молча не находит почти ничего.
# Coder-модули ImageMagick imagick грузит через dlopen, так что их зависимости
# (libheif для AVIF/HEIC и т.п.) в ldd самого imagick.so не видны — сканируем
# и модули.
RUN set -eux; \
    extdir="$(php -r 'echo ini_get("extension_dir");')"; \
    ldd /usr/local/bin/php /usr/local/sbin/php-fpm "$extdir"/*.so \
        /usr/lib/*/ImageMagick-*/modules-*/coders/*.so \
        | awk '/=> \//{print $3}' \
        | sort -u \
        | xargs -r realpath -e \
        | sort -u \
        | xargs -r dpkg-query -S 2>/dev/null \
        | awk '/^diversion by /{print $3; next} {sub(/:.*/, ""); print}' \
        | tr ',' '\n' | tr -d ' ' \
        | grep -v '^$' | sort -u > /runtime-deps.txt; \
    # делегаты ImageMagick (heic, jxl и прочее) — не ldd-зависимость,
    # но без них imagick читает заметно меньше форматов
    core="$(grep -m1 '^libmagickcore-' /runtime-deps.txt || true)"; \
    if [ -n "$core" ] && apt-cache show "${core}-extra" >/dev/null 2>&1; then \
        echo "${core}-extra" >> /runtime-deps.txt; \
    fi; \
    # То же с рекомендациями libheif и ImageMagick: энкодеры AVIF/HEIC
    # (libheif-plugin-aomenc/x265) libheif грузит через dlopen, ghostscript и
    # шрифты imagick вызывает для PDF/EPS и текста. В ldd их нет, а рантайм
    # ставится с --no-install-recommends — без этого imagick молча перестаёт
    # писать AVIF.
    for p in $(grep -E '^(libheif[0-9]|libmagickcore-)' /runtime-deps.txt); do \
        apt-cache show --no-all-versions "$p" \
            | sed -n 's/^Recommends: //p' \
            | tr ',' '\n' | sed 's/^ *//; s/[ |(].*//'; \
    done >> /runtime-deps.txt; \
    echo ca-certificates >> /runtime-deps.txt; \
    sort -u -o /runtime-deps.txt /runtime-deps.txt; \
    cat /runtime-deps.txt; \
    # молча недосчитаться зависимостей тут страшнее всего: образ соберётся,
    # а упадёт уже у пользователя. Реально их около сорока.
    n="$(wc -l < /runtime-deps.txt)"; \
    [ "$n" -ge 20 ] || { echo "подозрительно короткий список зависимостей ($n)" >&2; exit 1; }

# Заголовки и build-система php без компилятора в рантайме бесполезны
RUN rm -rf /usr/local/include/php /usr/local/lib/php/build

# ---------------------------------------------------------------------------
# runtime: чистый Debian + готовый /usr/local. Тулчейна (353 МБ в php:*-fpm)
# здесь нет — соответственно docker-php-ext-install в наследниках не работает.
# ---------------------------------------------------------------------------
FROM debian:${DEBIAN_SUITE}-slim

ENV PHP_INI_DIR=/usr/local/etc/php

COPY --from=builder /runtime-deps.txt /tmp/runtime-deps.txt
RUN set -eux; \
    { echo 'Package: php*'; echo 'Pin: release *'; echo 'Pin-Priority: -1'; } \
        > /etc/apt/preferences.d/no-debian-php; \
    apt-get update; \
    apt-get upgrade -y; \
    apt-get install -y --no-install-recommends $(cat /tmp/runtime-deps.txt); \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/* /var/tmp/*

COPY --from=builder /usr/local /usr/local
COPY docker-entrypoint.sh /usr/local/bin/
COPY 00-defaults.ini /usr/local/etc/php/conf.d/
COPY zz-defaults.conf /usr/local/etc/php-fpm.d/

RUN set -eux; \
    ldconfig; \
    chmod +x /usr/local/bin/docker-entrypoint.sh; \
    mkdir -p /var/www/html; \
    chown www-data:www-data /var/www/html; \
    chmod 1777 /var/www/html; \
    php -v; \
    php -m; \
    php-fpm -t; \
    # AVIF imagick пишет через плагин libheif, который подгружается только в
    # момент записи — php -m его отсутствия не заметит
    php -r '$i = new Imagick(); $i->newImage(8, 8, "red"); $i->setImageFormat("avif"); exit(strlen($i->getImageBlob()) > 0 ? 0 : 1);'

WORKDIR /var/www/html

EXPOSE 9000
STOPSIGNAL SIGQUIT

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
