# PHP-FPM Docker Images

[![Docker Hub](https://img.shields.io/badge/Docker%20Hub-winterhearted%2Fphp--fpm-blue)](https://hub.docker.com/r/winterhearted/php-fpm)

Optimized PHP-FPM Docker images for development and production. Supports PHP 5.3 to 8.5.

**Author:** Winterhearted, [byte0.org](https://byte0.org) Laboratory
**Made for:** Internet Agency ["Pantera"](https://pantera.kz)

## Quick Start

```bash
docker pull winterhearted/php-fpm:8.3
docker run -d -v $(pwd):/var/www/html -p 9000:9000 winterhearted/php-fpm:8.3
```

## Building & Publishing

```bash
# Build specific versions
./build.sh 8.3 8.4

# Build all versions
./build.sh --all

# Push to registry
./push.sh 8.3 8.4
./push.sh --all

# Custom image name
./build.sh -n mycompany/php 8.3
./push.sh -n mycompany/php 8.3
```

## Available Versions

| Current | Legacy |
|---------|--------|
| 8.5 (dev), 8.4, 8.3, 8.2, 8.1 | 8.0, 7.4, 7.3, 7.2, 7.1, 7.0, 5.6, 5.5, 5.4, 5.3 |

Each version has tags: `X.Y`, `X.Y-latest`, `X.Y.Z` (exact)

## Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `PHP_DATE_TIMEZONE` | Timezone | `UTC` |
| `PHP_MEMORY_LIMIT` | Memory limit | `256M` |
| `PHP_MAX_EXECUTION_TIME` | Max execution time (sec) | `300` |
| `PHP_MAX_INPUT_TIME` | Max input time (sec) | `300` |
| `PHP_POST_MAX_SIZE` | Max POST size | `100M` |
| `PHP_UPLOAD_MAX_FILESIZE` | Max upload size | `100M` |
| `PHP_ENABLE_OPCACHE` | Enable OPcache (5.5+) | `1` / `0` |
| `PHP_ENABLE_JIT` | Enable JIT (8.0+) | `1` / `0` |

## Included Extensions

PDO, MySQL, PostgreSQL, GD, ImageMagick, OPcache, Zip, Intl, BCMath, EXIF, SOAP, MBString, cURL, OpenSSL

## License

MIT
