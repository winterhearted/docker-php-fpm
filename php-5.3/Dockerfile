FROM debian:jessie

ENV PHP_VERSION=5.3.29
ENV PHP_URL="https://museum.php.net/php5/php-5.3.29.tar.gz"

COPY docker-entrypoint.sh /usr/local/bin/

RUN sed -i 's/deb.debian.org/archive.debian.org/g' /etc/apt/sources.list && \
    sed -i 's/security.debian.org/archive.debian.org/g' /etc/apt/sources.list && \
    sed -i '/jessie-updates/d' /etc/apt/sources.list && \
    apt-get update && \
    apt-get install -y --force-yes --no-install-recommends \
        autoconf dpkg-dev file g++ gcc libc-dev make pkg-config re2c ca-certificates curl \
        libcurl4-openssl-dev libedit-dev libreadline-dev libsqlite3-dev libssl-dev libxml2-dev zlib1g-dev \
        libpng-dev libjpeg-dev libfreetype6-dev \
        libpq-dev libicu-dev libzip-dev libmagickwand-dev libmagickcore-dev \
        libmysqlclient-dev && \
    curl -fsSL "$PHP_URL" -o php.tar.gz && \
    mkdir -p /usr/src/php && \
    tar -xzf php.tar.gz -C /usr/src/php --strip-components=1 && \
    rm php.tar.gz && \
    mkdir -p /usr/include/freetype2/freetype && \
    ln -sf /usr/include/freetype2/freetype.h /usr/include/freetype2/freetype/freetype.h && \
    cd /usr/src/php && \
    ./configure \
        --with-config-file-path=/usr/local/etc/php \
        --with-config-file-scan-dir=/usr/local/etc/php/conf.d \
        --enable-fpm \
        --with-fpm-user=www-data \
        --with-fpm-group=www-data \
        --enable-mbstring \
        --enable-zip \
        --enable-bcmath \
        --enable-exif \
        --enable-intl \
        --enable-soap \
        --with-curl \
        --with-openssl \
        --with-readline \
        --with-zlib \
        --with-gd \
        --with-jpeg-dir=/usr \
        --with-png-dir=/usr \
        --with-freetype-dir=/usr \
        --with-pdo-mysql \
        --with-pdo-pgsql \
        --with-mysql \
        --with-mysqli \
        --with-pgsql && \
    sed -i 's/^EXTRA_LIBS = /EXTRA_LIBS = -Wl,--no-as-needed -lssl -lcrypto -lstdc++ /' Makefile && \
    make -j"$(nproc)" && \
    make install && \
    mkdir -p /usr/local/etc/php/conf.d && \
    cp /usr/src/php/php.ini-production /usr/local/etc/php/php.ini && \
    pecl install imagick-3.3.0 && \
    echo "extension=imagick.so" > /usr/local/etc/php/conf.d/imagick.ini && \
    cp /usr/local/etc/php-fpm.conf.default /usr/local/etc/php-fpm.conf && \
    sed -i 's/;daemonize = yes/daemonize = no/' /usr/local/etc/php-fpm.conf && \
    sed -i 's/listen = 127.0.0.1:9000/listen = 9000/' /usr/local/etc/php-fpm.conf && \
    rm -rf /usr/src/php && \
    apt-get purge -y --force-yes autoconf dpkg-dev file g++ gcc make re2c && \
    apt-get autoremove -y --force-yes && \
    rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/* /tmp/* /var/tmp/* && \
    chmod +x /usr/local/bin/docker-entrypoint.sh

WORKDIR /var/www/html

EXPOSE 9000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["php-fpm"]
