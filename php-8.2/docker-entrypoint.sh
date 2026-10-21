#!/bin/sh
set -e

setup_php_config() {
    # PHP_DATE_TIMEZONE
    if [ ! -z "$PHP_DATE_TIMEZONE" ]; then
        echo "date.timezone = $PHP_DATE_TIMEZONE" > /usr/local/etc/php/conf.d/date-timezone.ini
    fi

    # PHP_ENABLE_OPCACHE
    if [ ! -z "$PHP_ENABLE_OPCACHE" ]; then
        if [ "$PHP_ENABLE_OPCACHE" = "0" ] || [ "$PHP_ENABLE_OPCACHE" = "false" ]; then
            echo "opcache.enable=0" > /usr/local/etc/php/conf.d/opcache-enable.ini
            echo "opcache.enable_cli=0" >> /usr/local/etc/php/conf.d/opcache-enable.ini
        else
            echo "opcache.enable=1" > /usr/local/etc/php/conf.d/opcache-enable.ini
            echo "opcache.enable_cli=1" >> /usr/local/etc/php/conf.d/opcache-enable.ini
        fi
    fi

    # PHP_ENABLE_JIT
    if [ ! -z "$PHP_ENABLE_JIT" ]; then
        if [ "$PHP_ENABLE_JIT" = "1" ] || [ "$PHP_ENABLE_JIT" = "true" ]; then
            echo "opcache.jit_buffer_size=100M" > /usr/local/etc/php/conf.d/opcache-jit.ini
            echo "opcache.jit=1255" >> /usr/local/etc/php/conf.d/opcache-jit.ini
        else
            echo "opcache.jit=off" > /usr/local/etc/php/conf.d/opcache-jit.ini
        fi
    fi

    # PHP_MAX_EXECUTION_TIME
    if [ ! -z "$PHP_MAX_EXECUTION_TIME" ]; then
        echo "max_execution_time = $PHP_MAX_EXECUTION_TIME" > /usr/local/etc/php/conf.d/max-execution-time.ini
    fi

    # PHP_MAX_INPUT_TIME
    if [ ! -z "$PHP_MAX_INPUT_TIME" ]; then
        echo "max_input_time = $PHP_MAX_INPUT_TIME" > /usr/local/etc/php/conf.d/max-input-time.ini
    fi

    # PHP_MEMORY_LIMIT
    if [ ! -z "$PHP_MEMORY_LIMIT" ]; then
        echo "memory_limit = $PHP_MEMORY_LIMIT" > /usr/local/etc/php/conf.d/memory-limit.ini
    fi

    # PHP_POST_MAX_SIZE
    if [ ! -z "$PHP_POST_MAX_SIZE" ]; then
        echo "post_max_size = $PHP_POST_MAX_SIZE" > /usr/local/etc/php/conf.d/post-max-size.ini
    fi

    # PHP_UPLOAD_MAX_FILESIZE
    if [ ! -z "$PHP_UPLOAD_MAX_FILESIZE" ]; then
        echo "upload_max_filesize = $PHP_UPLOAD_MAX_FILESIZE" > /usr/local/etc/php/conf.d/upload-max-filesize.ini
    fi
}

setup_php_config

exec docker-php-entrypoint "$@"