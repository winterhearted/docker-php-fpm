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

    # PHP_DISPLAY_ERRORS
    # Без php.ini ошибки идут прямо в ответ. В лог они пишутся в любом случае
    # (log_errors включён в zz-defaults.conf), с 0 остаются только там
    if [ ! -z "$PHP_DISPLAY_ERRORS" ]; then
        if [ "$PHP_DISPLAY_ERRORS" = "0" ] || [ "$PHP_DISPLAY_ERRORS" = "false" ]; then
            echo "display_errors = Off" > /usr/local/etc/php/conf.d/display-errors.ini
            echo "display_startup_errors = Off" >> /usr/local/etc/php/conf.d/display-errors.ini
        else
            echo "display_errors = On" > /usr/local/etc/php/conf.d/display-errors.ini
            echo "display_startup_errors = On" >> /usr/local/etc/php/conf.d/display-errors.ini
        fi
    fi

    # PHP_ERROR_LOG
    # Каталог должен быть доступен на запись www-data. Если нет, PHP молча
    # пишет в docker logs, так что ошибки не теряются
    if [ ! -z "$PHP_ERROR_LOG" ]; then
        echo "error_log = $PHP_ERROR_LOG" > /usr/local/etc/php/conf.d/error-log.ini
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

setup_fpm_pool() {
    if [ -z "$PHP_FPM_PM$PHP_FPM_MAX_CHILDREN$PHP_FPM_START_SERVERS$PHP_FPM_MIN_SPARE_SERVERS$PHP_FPM_MAX_SPARE_SERVERS$PHP_FPM_MAX_REQUESTS" ]; then
        return
    fi

    start="$PHP_FPM_START_SERVERS"
    min_spare="$PHP_FPM_MIN_SPARE_SERVERS"
    max_spare="$PHP_FPM_MAX_SPARE_SERVERS"

    # Если задан только max_children, остальное масштабируем в той же
    # пропорции, что и умолчания (3/2/5 при 12). Иначе при max_children
    # меньше 5 fpm не стартует: запасных не может быть больше, чем воркеров
    if [ ! -z "$PHP_FPM_MAX_CHILDREN" ]; then
        n="$PHP_FPM_MAX_CHILDREN"
        : "${start:=$(( (n + 3) / 4 ))}"
        : "${min_spare:=$(( (n + 5) / 6 ))}"
        : "${max_spare:=$(( (n * 5 + 11) / 12 ))}"
    fi

    put() {
        [ -z "$2" ] || echo "$1 = $2"
    }

    # Идёт после zz-defaults.conf и перекрывает его
    {
        echo "[www]"
        put pm "$PHP_FPM_PM"
        put pm.max_children "$PHP_FPM_MAX_CHILDREN"
        put pm.start_servers "$start"
        put pm.min_spare_servers "$min_spare"
        put pm.max_spare_servers "$max_spare"
        put pm.max_requests "$PHP_FPM_MAX_REQUESTS"
    } > /usr/local/etc/php-fpm.d/zz-env.conf
}

setup_php_config
setup_fpm_pool

exec docker-php-entrypoint "$@"