# php-fpm, batteries included

PHP-FPM with the extensions you'd end up installing anyway, already in. Tune it with env vars instead of baking your own ini files. PHP 5.3 through 8.5.

Built at the [byte0.org](https://byte0.org) lab for internal use at [Pantera](https://pantera.kz), a web studio. Public because there's no reason not to be.

## Run it

```bash
docker run -d -v $(pwd):/var/www/html winterhearted/php-fpm:8.4
```

Listens on 9000, serves from `/var/www/html`. Point nginx at it, done.

## Tags

`8.5` `8.4` `8.3` `8.2` `8.1` — pick one.

`8.0` `7.4` `7.3` `7.2` `7.1` `7.0` `5.6` `5.5` `5.4` `5.3` — EOL, kept for old projects. The 5.x ones are built from source.

Each has a `-latest` alias and exact patches too (`8.4.23`). amd64, arm64, riscv64.

### `-vips`

`8.5-vips` `8.4-vips` `8.3-vips` `8.2-vips` — same image plus libvips and FFI turned on. Also as `8.4-latest-vips`, `8.4.23-vips`, etc.

Use it with [php-vips](https://github.com/libvips/php-vips) 2.x, which talks to the library over FFI. The old pecl `vips` extension has been dead since PHP 8.0, so it's not here.

libvips isn't small and most projects don't need it, hence the separate tag — the plain images stay lean.

### `8.6-rc` — experimental

`8.6-rc` tracks the upstream PHP 8.6 alpha/RC images and is rebuilt weekly. Also `8.6-rc-vips`, and dated snapshots like `8.6-rc-20260805` if you want to pin something that won't move under you mid-debug.

For seeing what breaks ahead of the release, nothing more. The feature set isn't frozen, so things will change between rebuilds and some of them will change under you. There's deliberately no `8.6` or `8.6-latest` tag — those stay empty until 8.6 actually ships.

One difference worth knowing: imagick is built from its git master here, because the last released version doesn't compile against 8.6 yet. amd64, arm64, riscv64, same as everything else.

## Knobs

| Var | Sets |
|---|---|
| `PHP_DATE_TIMEZONE` | `date.timezone` |
| `PHP_MEMORY_LIMIT` | `memory_limit`, e.g. `256M` |
| `PHP_MAX_EXECUTION_TIME` | seconds |
| `PHP_MAX_INPUT_TIME` | seconds |
| `PHP_POST_MAX_SIZE` | e.g. `100M` |
| `PHP_UPLOAD_MAX_FILESIZE` | e.g. `100M` |
| `PHP_ENABLE_OPCACHE` | `1`/`0`, CLI included |
| `PHP_ENABLE_JIT` | `1`/`0`, 8.0+ |

Leave one unset and you get PHP's default. Each just drops a file into `conf.d/`, nothing clever going on.

## What's inside

pdo (mysql / pgsql / sqlite), mysqli, gd with jpeg/png/webp/avif/freetype, imagick, opcache, intl, zip, bcmath, exif, soap, mbstring, curl, openssl, sodium, and the usual dom/xml set.

Run `php -m` if you want the exact list for a given tag.

## Heads up

8.2–8.5 are built in two stages: extensions get compiled in a throwaway builder, the final image is plain Debian plus the finished PHP. Much smaller, but no compiler in there — `docker-php-ext-install` in a derived image won't work. Everything you'd normally add is already baked in; if something's genuinely missing, open an issue.

riscv64 sometimes trails the other arches by a patch. Moving tags like `8.4` don't wait for it — you may get a slightly older build there.

MIT.
