ARG PHP_BASE=8.6-rc-fpm
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
#
# Отличие от 8.2–8.5: imagick ставится из master, а не с pecl. Причины две.
# Во-первых, из образов 8.6 выкинули PEAR целиком, команды pecl там просто нет.
# Во-вторых, в 8.6 из php.h убрали XtOffsetOf (легаси-макрос из X11), а
# последний стабильный релиз imagick им ещё пользуется и не компилируется.
# В master это уже починено. Когда выйдет релиз imagick с поддержкой 8.6,
# этот блок можно будет свести к тому же виду, что в 8.5.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libzip-dev libjpeg62-turbo-dev libpng-dev libwebp-dev libavif-dev \
        libfreetype-dev zlib1g-dev libpq-dev libicu-dev libxml2-dev \
        libmagickwand-dev libmagickcore-dev libffi-dev git; \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp --with-avif; \
    docker-php-ext-install -j"$(nproc)" \
        pdo pdo_mysql pdo_pgsql mysqli gd zip intl bcmath exif soap ffi; \
    git clone --depth 1 https://github.com/Imagick/imagick.git /usr/src/php/ext/imagick; \
    imagick_ref="$(git -C /usr/src/php/ext/imagick rev-parse --short HEAD)"; \
    rm -rf /usr/src/php/ext/imagick/.git; \
    # без подстановки phpversion('imagick') вернёт литерал @PACKAGE_VERSION@:
    # его подставляет упаковщик pecl, которого тут нет
    grep -rl '@PACKAGE_VERSION@' /usr/src/php/ext/imagick \
        | xargs -r sed -i "s/@PACKAGE_VERSION@/dev-g${imagick_ref}/"; \
    docker-php-ext-install -j"$(nproc)" imagick; \
    php -r 'exit(extension_loaded("imagick") ? 0 : 1);'; \
    php -r 'echo "imagick ", phpversion("imagick"), ", форматов: ", count(Imagick::queryFormats()), PHP_EOL;'; \
    rm -rf /usr/src/php/ext/imagick; \
    rm -f /usr/local/etc/php/conf.d/docker-php-ext-ffi.ini

# В php:8.5-fpm mbstring собран, в php:8.6-rc-fpm — уже нет, хотя из php-src он
# никуда не делся. Ставим сами. Проверка "а вдруг уже есть" не лишняя: если
# upstream вернёт mbstring в базу, повторная установка положит второй ini
# в conf.d и php будет ругаться на дубль модуля.
# libonig (oniguruma) тянется как рантайм-зависимость сама — она видна в ldd
# mbstring.so, а список рантайм-пакетов считается именно по ldd.
RUN set -eux; \
    if php -m | grep -qix mbstring; then \
        echo "mbstring уже есть в базовом образе, пропускаю"; \
    else \
        apt-get install -y --no-install-recommends libonig-dev; \
        docker-php-ext-install -j"$(nproc)" mbstring; \
    fi; \
    php -r 'exit(function_exists("mb_substr") ? 0 : 1);'

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
    # Пререлизная база меняется каждую неделю и может тихо недосчитаться
    # расширения (так уехал mbstring между 8.5 и 8.6). Лучше упасть тут,
    # чем отдать людям образ без половины обещанного.
    # Проверяем через extension_loaded, а не грепом по `php -m`: там имена
    # печатаются как зарегистрированы, и opcache, например, зовётся
    # "Zend OPcache".
    php -r '$need = ["mbstring","imagick","gd","intl","zip","pdo_mysql","pdo_pgsql","mysqli","bcmath","exif","soap","curl","openssl","Zend OPcache","sodium"]; $miss = array_values(array_filter($need, fn($e) => !extension_loaded($e))); if ($miss) { fwrite(STDERR, "нет расширений: " . implode(", ", $miss) . PHP_EOL); exit(1); } if (!function_exists("mb_substr")) { fwrite(STDERR, "mbstring есть, а mb_substr нет" . PHP_EOL); exit(1); } echo "проверка расширений пройдена", PHP_EOL;'; \
    # AVIF imagick пишет через плагин libheif, который подгружается только в
    # момент записи — php -m его отсутствия не заметит
    php -r '$i = new Imagick(); $i->newImage(8, 8, "red"); $i->setImageFormat("avif"); exit(strlen($i->getImageBlob()) > 0 ? 0 : 1);'

WORKDIR /var/www/html

EXPOSE 9000
STOPSIGNAL SIGQUIT

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
