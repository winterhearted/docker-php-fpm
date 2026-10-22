# PHP-FPM Docker Images

[![Docker Hub](https://img.shields.io/badge/Docker%20Hub-winterhearted%2Fphp--fpm-blue)](https://hub.docker.com/r/winterhearted/php-fpm)

Build pipeline for [`winterhearted/php-fpm`](https://hub.docker.com/r/winterhearted/php-fpm): multi-arch (amd64, arm64, riscv64) PHP-FPM images, PHP 5.3 through 8.5 plus an `8.6-rc` prerelease track.

**Author:** Winterhearted, [byte0.org](https://byte0.org) Laboratory
**Made for:** Internet Agency ["Pantera"](https://pantera.kz)

This README is about building and publishing. For using the images — tags, env vars, extensions — see [README_DOCKERHUB.md](README_DOCKERHUB.md), which is also the description on Docker Hub.

## How it works

There's no CI. Each architecture is built natively on its own machine — an amd64 VPS (rootless podman), an arm64 board and an Orange Pi RV2 for riscv64 (docker) — and all of them run the same scripts from this repo.

Every machine pushes only its own **arch-suffixed** tags (`8.4.26-riscv64`, `8.4-riscv64`, …). The plain tags (`8.4.26`, `8.4`, `8.4-latest`) are multi-arch manifests written only by `stitch.sh`, which reads whatever arch tags currently exist in the registry and merges them. Nothing is ever pushed to a plain tag directly — that would overwrite the manifest with a single-arch image.

Because stitching is a pure recalculation from the registry, machines don't coordinate: they rebuild on their own schedules, and the manifest fills in as each arch catches up.

- `X.Y.Z` is stitched only from arches that built exactly that patch.
- `X.Y` / `X.Y-latest` is stitched from the newest `X.Y-<arch>` of each arch, so a slow riscv64 never holds amd64/arm64 back.

### Tags

| Tag | Moves? | Notes |
|---|---|---|
| `8.4`, `8.4-latest` | yes | latest patch of the branch |
| `8.4.26` | no | exact patch |
| `8.4-vips`, `8.4-latest-vips`, `8.4.26-vips` | as above | variant: image + libvips/FFI (8.2+) |
| `8.6-rc`, `8.6-rc-vips` | yes | current upstream alpha/RC, rebuilt weekly |
| `8.6-rc-YYYYMMDD` | no | weekly snapshot; date is **UTC** so all machines produce the same tag |
| `…-<arch>` | — | per-arch building blocks, not meant to be pulled |

`8.6` / `8.6-latest` are intentionally left empty until 8.6 ships.

## Layout

```
php-X.Y/
  Dockerfile             base image; 8.2+ take ARG PHP_BASE (e.g. 8.4.26-fpm)
  Dockerfile.<variant>   optional variant built on top (ARG BASE_IMAGE), e.g. Dockerfile.vips
  docker-entrypoint.sh   turns PHP_* env vars into conf.d/*.ini, PHP_FPM_* into php-fpm.d/zz-env.conf
  00-defaults.ini        8.2+: image's php.ini defaults (loaded first, env overrides)
  zz-defaults.conf       8.2+: image's FPM pool defaults (env and later-sorted files override)
engine.sh                docker/podman abstraction, sourced by every script
architectures.conf       arches stitch.sh merges; keep identical on all machines
check-updates.sh         nightly: find new upstream patches, build them, stitch
backfill.sh              build + push exact patches (X.Y.Z-<arch>), optionally move X.Y-<arch>
build-rc.sh              weekly: rebuild 8.6-rc from php:8.6-rc-fpm, push dated snapshot
stitch.sh                merge arch tags into multi-arch manifests
build.sh, push.sh        manual build/push of whole branches (used for EOL 5.3–8.1)
php-*.service, *.timer   systemd user units for the two schedules
```

Variants are discovered by file: drop a `Dockerfile.<name>` into `php-X.Y/` and every script builds, tags and stitches `X.Y-<name>` alongside the base image.

8.2+ are two-stage builds: extensions are compiled in a throwaway builder, the final stage is plain Debian plus the finished PHP. The builder checks that `php:X.Y-fpm` is on the Debian suite named in `ARG DEBIAN_SUITE` and fails loudly when upstream moves to a new release — bump the arg when that happens.

## Automation

Two systemd **user** timers on each build machine:

| Timer | When (Asia/Almaty) | Runs |
|---|---|---|
| `php-check-updates.timer` | daily 03:00 ± 20 min | `check-updates.sh` |
| `php-rc-rebuild.timer` | Mondays 09:00 ± 30 min (= 04:00 UTC) | `build-rc.sh` |

Both services first run `git pull --ff-only` in `~/php-build` (failure is ignored — the build then uses whatever is checked out). Both timers are `Persistent=true`, so a run missed while the machine was off fires at boot.

**`check-updates.sh`** asks the Docker Hub API for `php:X.Y.Z-fpm` tags of 8.2–8.5 and compares them with `.build-state` — the last patch and base digest this machine built. Every missing patch is built in order via `backfill.sh --stitch`, the newest one also with `--set-moving`. If the patch is the same but the digest changed (upstream rebuilt the base, e.g. a Debian security fix), it force-rebuilds. State is saved after each successful push, so a failed run resumes where it stopped.

**`build-rc.sh`** rebuilds 8.6-rc unconditionally (`--no-cache --pull`) and refuses to publish if the base image has moved on to another branch (e.g. once `php:8.6-rc-fpm` starts pointing at 8.7).

**Cleanup.** Images are built from scratch every time, so nothing local is reused. After a successful push the scripts call `eng_cleanup` (in `engine.sh`), which removes the just-pushed images with all their tags, dangling images and the now-dangling BuildKit cache. Failed or `--build-only` builds keep their images. Before this was added, images and cache filled the riscv64 board's 57 GB card in under three months.

## Setting up a build machine

Needs: docker (with buildx) or podman, `git`, `curl`, `python3`, and `docker login` / `podman login` with push access to `winterhearted/php-fpm`.

```bash
# 1. Code — the repo is private; use a read-only deploy key per machine
ssh-keygen -t ed25519 -N '' -f ~/.ssh/php-fpm-deploy -C "<host> php-fpm deploy"
cat >> ~/.ssh/config <<'EOF'
Host github-php-fpm
    HostName github.com
    User git
    IdentityFile ~/.ssh/php-fpm-deploy
    IdentitiesOnly yes
EOF
#    add ~/.ssh/php-fpm-deploy.pub as a deploy key (no write access), then:
git clone git@github-php-fpm:winterhearted/php-fpm.git ~/php-build

# 2. Remember the current upstream heads instead of building all history
~/php-build/check-updates.sh --seed

# 3. Timers
mkdir -p ~/.config/systemd/user
cp ~/php-build/php-*.service ~/php-build/php-*.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now php-check-updates.timer php-rc-rebuild.timer
sudo loginctl enable-linger "$USER"   # otherwise user timers only run while you're logged in
```

`git pull` updates the copies in `~/php-build`, not the installed units — after changing a `.service`/`.timer`, copy them again and `daemon-reload`.

## Manual operations

```bash
./check-updates.sh 8.4 8.5            # check/build only these branches
./backfill.sh 8.4.18 8.4.19           # push exact patches, don't touch 8.4-<arch>
./backfill.sh --build-only 8.5.3      # build locally to test, no push, no cleanup
./backfill.sh --set-moving --stitch 8.4.26
./build-rc.sh --date 20261019         # rc snapshot under a specific (UTC) date
./stitch.sh 8.4 8.4.26 8.4-vips       # re-stitch manifests from what's in the registry
./stitch.sh --no-latest 8.6-rc        # rc tags: no X.Y-latest alias

./build.sh 7.4 8.0 && ./push.sh --stitch 7.4 8.0   # EOL branches
```

Force a specific engine with `ENGINE=podman ./…`.

## Logs

```bash
systemctl --user list-timers 'php-*'
journalctl _SYSTEMD_USER_UNIT=php-check-updates.service --since today
journalctl _SYSTEMD_USER_UNIT=php-rc-rebuild.service --since -7d
```

On some machines (the Orange Pi among them) `journalctl --user -u …` finds no entries; the `_SYSTEMD_USER_UNIT=` form reads the same lines from the system journal and works everywhere.

## License

MIT
