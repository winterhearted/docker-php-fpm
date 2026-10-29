# PHP-FPM Docker Images

[![nightly](https://github.com/winterhearted/docker-php-fpm/actions/workflows/nightly.yml/badge.svg)](https://github.com/winterhearted/docker-php-fpm/actions/workflows/nightly.yml)
[![Docker Hub](https://img.shields.io/badge/Docker%20Hub-winterhearted%2Fphp--fpm-blue)](https://hub.docker.com/r/winterhearted/php-fpm)

Build pipeline for [`winterhearted/php-fpm`](https://hub.docker.com/r/winterhearted/php-fpm): multi-arch (amd64, arm64, riscv64) PHP-FPM images, PHP 5.3 through 8.5 plus an `8.6-rc` prerelease track.

**Author:** Winterhearted, [byte0.org](https://byte0.org) Laboratory
**Made for:** Internet Agency ["Pantera"](https://pantera.kz)

This README is about building and publishing. For using the images — tags, env vars, extensions — see [README_DOCKERHUB.md](README_DOCKERHUB.md), which is also the description on Docker Hub.

## How it works

Builds run on GitHub Actions, natively for each architecture: amd64 on `ubuntu-24.04`, arm64 on `ubuntu-24.04-arm` (both free for public repos), riscv64 on `ubuntu-24.04-riscv` from [RISE RISC-V Runners](https://riscv-runners.riseproject.dev/) (free for open source, needs their GitHub App installed on the account). No QEMU. RISE is a shared pool, so riscv64 jobs may wait in the queue for a while; a full 8.4 build there takes about 20 minutes.

Every build pushes only **arch-suffixed** tags (`8.4.27-amd64`, `8.4-amd64`, …). The plain tags (`8.4.27`, `8.4`, `8.4-latest`) are multi-arch manifests written only by `stitch.sh`, which reads whatever arch tags currently exist in the registry and merges them. Nothing is ever pushed to a plain tag directly — that would overwrite the manifest with a single-arch image.

Because stitching is a pure recalculation from the registry, builders don't coordinate: runners (or a self-hosted box) publish on their own schedules, and the manifest fills in as each arch catches up.

- `X.Y.Z` is stitched only from arches that built exactly that patch.
- `X.Y` / `X.Y-latest` is stitched from the newest `X.Y-<arch>` of each arch, so a slow riscv64 never holds amd64/arm64 back.

Nothing keeps state between runs. What's been built is read from the registry: the newest `X.Y.Z-<arch>` tag, plus the `org.opencontainers.image.base.digest` label on it — the digest of the exact `php:X.Y.Z-fpm` platform manifest it was built from (the build pins `FROM` to that digest).

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
  Dockerfile             base image; 8.2+ take ARG PHP_BASE (e.g. 8.4.27-fpm or 8.4.27-fpm@sha256:…)
  Dockerfile.<variant>   optional variant built on top (ARG BASE_IMAGE), e.g. Dockerfile.vips
  docker-entrypoint.sh   turns PHP_* env vars into conf.d/*.ini, PHP_FPM_* into php-fpm.d/zz-env.conf
  00-defaults.ini        8.2+: image's php.ini defaults (loaded first, env overrides)
  zz-defaults.conf       8.2+: image's FPM pool defaults (env and later-sorted files override)
.github/workflows/
  nightly.yml            daily: new upstream patches / rebuilt bases for 8.2–8.5
  rc.yml                 weekly: 8.6-rc
  backfill.yml           manual: exact patches
  eol.yml                manual: whole EOL branches (5.3–8.1)
engine.sh                docker/podman abstraction, sourced by every script
hub.py                   Docker Hub API queries: upstream patches/digests, our newest tags
architectures.conf       arches stitch.sh merges
check-updates.sh         find what to build (--plan prints it for CI) and build it
backfill.sh              build + push exact patches (X.Y.Z-<arch>), optionally move X.Y-<arch>
build-rc.sh              rebuild 8.6-rc from php:8.6-rc-fpm, push dated snapshot
stitch.sh                merge arch tags into multi-arch manifests
build.sh, push.sh        build/push whole branches (used for EOL 5.3–8.1)
php-*.service, *.timer   systemd user units for a self-hosted builder
```

Variants are discovered by file: drop a `Dockerfile.<name>` into `php-X.Y/` and every script builds, tags and stitches `X.Y-<name>` alongside the base image.

8.2+ are two-stage builds: extensions are compiled in a throwaway builder, the final stage is plain Debian plus the finished PHP. The builder checks that `php:X.Y-fpm` is on the Debian suite named in `ARG DEBIAN_SUITE` and fails loudly when upstream moves to a new release — bump the arg when that happens.

## Automation

| Workflow | When | Does |
|---|---|---|
| `nightly` | daily 21:00 UTC (03:00 Asia/Almaty) | `check-updates.sh --plan` → build matrix → one stitch |
| `rc` | Mondays 04:00 UTC | `build-rc.sh` on each arch → one stitch |
| `backfill` | manual | `backfill.sh` for given patches on chosen arches → stitch |
| `eol` | manual | `build.sh` + `push.sh` for given branches → stitch |

Every workflow has the same shape: a matrix job per architecture that only pushes `-<arch>` tags, then a single `stitch` job after all of them (if each build stitched on its own, parallel runners would overwrite each other's manifests).

**`nightly`.** `check-updates.sh --plan` lists `php:X.Y.Z-fpm` tags of 8.2–8.5 on Docker Hub with their per-arch digests and compares them with our own tags. For each branch and arch: every patch newer than our newest `X.Y.Z-<arch>` gets built, the newest one also moves `X.Y-<arch>`; if the patch is the same but the base digest differs from our label (upstream rebuilt the base, e.g. a Debian security fix), the head is force-rebuilt. A patch upstream hasn't published for some arch yet is simply picked up on a later night. A failed build is retried the next night by the same logic — there's nothing to resume.

The digest compared is the platform manifest's, not the index's: the official index gets rewritten as upstream finishes other arches, and comparing it would rebuild amd64 because of someone's riscv64 build.

**`rc`** rebuilds 8.6-rc unconditionally and refuses to publish if the base image has moved on to another branch (e.g. once `php:8.6-rc-fpm` starts pointing at 8.7). The snapshot date is computed once and passed to all arches.

**Keeping the schedule alive.** GitHub disables cron workflows in public repos after 60 days without commits. The `keepalive` job in `nightly` re-enables `nightly` and `rc` through the API every day, which resets that counter.

## Setup

1. Docker Hub → Account settings → Personal access tokens: create a token with **Read & Write** access.
2. Save it as a repository secret:
   ```bash
   gh secret set DOCKERHUB_TOKEN -R winterhearted/docker-php-fpm
   ```
3. Install the [RISE RISC-V Runners](https://riscv-runners.riseproject.dev/) GitHub App (Personal for a user account) — without it riscv64 jobs queue forever.
4. Settings → Actions → General: make sure Actions are allowed. That's it — the Hub username is in the workflows' `env`.

## Manual operations

From GitHub (Actions tab → workflow → Run workflow) or with `gh`:

```bash
gh workflow run nightly                                   # run the nightly check now
gh workflow run nightly -f minors="8.4 8.5"
gh workflow run backfill -f versions="8.4.18 8.4.19"      # exact patches, X.Y untouched
gh workflow run backfill -f versions=8.4.27 -f set_moving=true
gh workflow run backfill -f versions=8.4.27 -f arches=riscv64 -f push=false   # trial build, nothing pushed
gh workflow run rc -f date=20261019                       # rc snapshot under a specific (UTC) date
gh workflow run eol -f minors="7.4 8.0"
gh run watch                                              # follow the latest run
```

The scripts still work on any machine with docker or podman — handy for testing before pushing:

```bash
./check-updates.sh --plan --arch amd64 --arch arm64   # what nightly would build, nothing is built
./backfill.sh --build-only 8.5.3                      # build locally, no push, no cleanup
./build-rc.sh --build-only
./stitch.sh 8.4 8.4.27 8.4-vips                       # re-stitch manifests from what's in the registry
./stitch.sh --with-variants 8.4 8.4.27                # same, variants included
./stitch.sh --no-latest 8.6-rc                        # rc tags: no X.Y-latest alias
```

Force a specific engine with `ENGINE=podman ./…` (podman needs `skopeo` for `check-updates.sh`).

## Self-hosted build machine

Not used at the moment — kept in case some arch has to be built off GitHub again (riscv64 used to be built this way on an Orange Pi RV2). Any arch can be built with systemd user timers; just don't let a self-hosted box and Actions build the same arch.

Needs: docker (with buildx) or podman + skopeo, `git`, `curl`, `python3`, and `docker login` / `podman login` with push access to `winterhearted/php-fpm`.

```bash
git clone https://github.com/winterhearted/docker-php-fpm.git ~/php-build

mkdir -p ~/.config/systemd/user
cp ~/php-build/php-*.service ~/php-build/php-*.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now php-check-updates.timer php-rc-rebuild.timer
sudo loginctl enable-linger "$USER"   # otherwise user timers only run while you're logged in
```

| Timer | When (Asia/Almaty) | Runs |
|---|---|---|
| `php-check-updates.timer` | daily 03:00 ± 20 min | `check-updates.sh` (builds and stitches its own arch) |
| `php-rc-rebuild.timer` | Mondays 09:00 ± 30 min (= 04:00 UTC) | `build-rc.sh` |

Both services first run `git pull --ff-only` (failure is ignored — the build then uses whatever is checked out). Both timers are `Persistent=true`, so a run missed while the machine was off fires at boot. `git pull` updates the copies in `~/php-build`, not the installed units — after changing a `.service`/`.timer`, copy them again and `daemon-reload`.

After a successful push the scripts call `eng_cleanup` (in `engine.sh`), which removes the just-pushed images, dangling images and the now-dangling BuildKit cache. Before this was added, images and cache filled the riscv64 board's 57 GB card in under three months.

Logs:

```bash
systemctl --user list-timers 'php-*'
journalctl _SYSTEMD_USER_UNIT=php-check-updates.service --since today
journalctl _SYSTEMD_USER_UNIT=php-rc-rebuild.service --since -7d
```

On some machines (the Orange Pi among them) `journalctl --user -u …` finds no entries; the `_SYSTEMD_USER_UNIT=` form reads the same lines from the system journal and works everywhere.

## License

MIT
