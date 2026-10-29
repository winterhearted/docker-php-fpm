#!/usr/bin/env python3
"""Запросы к публичному API Docker Hub (hub.docker.com, без токена).

  hub.py upstream MINOR            патчи php:X.Y.Z-fpm по всем linux-архитектурам:
                                   строки "X.Y.Z ARCH sha256:...", по возрастанию версии
  hub.py digest VERSION ARCH       дайджест linux/ARCH у php:VERSION-fpm
  hub.py ours IMAGE MINOR ARCH     старший X.Y.Z, для которого есть IMAGE:X.Y.Z-ARCH

Дайджест — платформенного манифеста, а не индекса: официальный индекс
переписывается по мере того, как upstream дособирает остальные архитектуры,
и по нему amd64 пересобирался бы из-за чужих riscv64-сборок.
"""

import json
import re
import sys
import urllib.request

API = "https://hub.docker.com/v2/repositories"

# Hub отдаёт теги от свежих к старым. У php на один патч приходится несколько
# десятков тегов (-cli, -alpine, -zts…), страница в 100 — это всего 3–4 патча,
# поэтому листаем ещё. 10 страниц хватает с запасом на месяц простоя.
MAX_PAGES = 10


def tags(repo, name_filter):
    url = f"{API}/{repo}/tags/?name={name_filter}&page_size=100"
    for _ in range(MAX_PAGES):
        if not url:
            return
        with urllib.request.urlopen(url, timeout=30) as r:
            page = json.load(r)
        yield from page["results"]
        url = page.get("next")


def platform_digest(tag, arch):
    for img in tag.get("images") or []:
        if img.get("os") == "linux" and img.get("architecture") == arch and img.get("digest"):
            return img["digest"]
    return None


def vkey(v):
    return tuple(int(x) for x in v.split("."))


def upstream(minor):
    pat = re.compile(r"^" + re.escape(minor) + r"\.[0-9]+-fpm$")
    rows = []
    for t in tags("library/php", f"{minor}."):
        if pat.match(t["name"]):
            for img in t.get("images") or []:
                # у arm/v5 и arm/v7 архитектура одна, "arm" — нам такие не нужны
                if img.get("os") == "linux" and img.get("digest") and img.get("architecture") != "arm":
                    rows.append((t["name"][:-4], img["architecture"], img["digest"]))
    for v, arch, d in sorted(rows, key=lambda r: (vkey(r[0]), r[1])):
        print(v, arch, d)


def digest(version, arch):
    with urllib.request.urlopen(f"{API}/library/php/tags/{version}-fpm", timeout=30) as r:
        d = platform_digest(json.load(r), arch)
    if not d:
        sys.exit(1)
    print(d)


def ours(image, minor, arch):
    pat = re.compile(r"^(" + re.escape(minor) + r"\.[0-9]+)-" + re.escape(arch) + r"$")
    found = [m.group(1) for t in tags(image, f"{minor}.") if (m := pat.match(t["name"]))]
    if found:
        print(max(found, key=vkey))


def main(argv):
    cmds = {"upstream": (upstream, 1), "digest": (digest, 2), "ours": (ours, 3)}
    if len(argv) < 2 or argv[1] not in cmds or len(argv) - 2 != cmds[argv[1]][1]:
        print(__doc__, file=sys.stderr)
        return 2
    cmds[argv[1]][0](*argv[2:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
