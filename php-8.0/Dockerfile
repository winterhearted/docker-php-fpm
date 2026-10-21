FROM php:8.0-fpm

COPY docker-entrypoint.sh /usr/local/bin/
RUN apt-get update && \
    apt-get upgrade -y && \
    apt-get install -y libzip-dev libjpeg-dev libjpeg62-turbo-dev libpng-dev libwebp-dev libfreetype-dev zlib1g-dev libpq-dev libmagickwand-dev libmagickcore-dev libicu-dev libxml2-dev && \
    pecl install imagick && \
    docker-php-ext-configure gd --with-freetype --with-jpeg --with-webp && \
    docker-php-ext-install pdo pdo_mysql pdo_pgsql mysqli gd opcache zip intl bcmath exif soap && \
    docker-php-ext-enable imagick zip && \
    apt-get install -y --no-install-recommends libgomp1 libicu67 libmagickwand-6.q16-6 libmagickcore-6.q16-6-extra && \
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
