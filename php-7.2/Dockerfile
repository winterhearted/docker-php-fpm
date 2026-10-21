FROM php:7.2-fpm

COPY docker-entrypoint.sh /usr/local/bin/
RUN sed -i 's/deb.debian.org/archive.debian.org/g' /etc/apt/sources.list && \
    sed -i 's/security.debian.org/archive.debian.org/g' /etc/apt/sources.list && \
    sed -i '/stretch-updates/d' /etc/apt/sources.list && \
    apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y libzip-dev libjpeg-dev libjpeg62-turbo-dev libpng-dev libwebp-dev libfreetype6-dev zlib1g-dev libpq-dev libmagickwand-dev libmagickcore-dev libicu-dev libxml2-dev && \
    pecl install imagick && \
    docker-php-ext-configure gd --with-jpeg-dir=/usr/lib --with-webp-dir=/usr/lib --with-freetype-dir=/usr/include/freetype2 && \
    docker-php-ext-install pdo pdo_mysql pdo_pgsql mysqli gd opcache zip intl bcmath exif soap && \
    docker-php-ext-enable imagick zip && \
    apt-get install -y --no-install-recommends libgomp1 libicu63 libmagickwand-6.q16-6 libmagickcore-6.q16-6-extra && \
    apt-get purge -y gcc g++ autoconf make && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/* && \
    rm -rf /var/cache/apt/archives/* && \
    rm -rf /tmp/* && \
    rm -rf /var/tmp/* && \
    chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /var/www/html

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
