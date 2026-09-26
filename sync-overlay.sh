#!/usr/bin/env bash
# sync-overlay.sh BANKONOS_DIR — copy the bankonOS parts into overlay/ and
# record exactly which bankonOS commit they came from (vendor.lock).
set -euo pipefail
src="$(readlink -f "${1:?usage: sync-overlay.sh /path/to/bankonOS}")"
here="$(cd "$(dirname "$0")" && pwd)"
o="${here}/overlay"
[[ -f "${src}/builds/ram/bankon-ram" ]] || { echo "${src} is not a bankonOS checkout" >&2; exit 1; }

install -D -m 0755 "${src}/builds/ram/bankon-ram"                       "${o}/usr/local/bin/bankon-ram"
install -D -m 0755 "${src}/builds/ram/amnesia/bankon-amnesia"           "${o}/usr/local/sbin/bankon-amnesia"
install -D -m 0644 "${src}/builds/ram/amnesia/bankon-amnesia.default"   "${o}/etc/default/bankon-amnesia"
install -D -m 0755 "${src}/builds/ram/alpine/bankon-amnesia.openrc"     "${o}/etc/init.d/bankon-amnesia"
install -D -m 0644 "${src}/builds/versions.env"                         "${o}/opt/bankonme/builds/versions.env"
install -D -m 0644 "${src}/builds/lib/common.sh"                        "${o}/opt/bankonme/builds/lib/common.sh"
install -D -m 0755 "${src}/builds/alpine/chomsky.build"                 "${o}/opt/bankonme/builds/alpine/chomsky.build"
install -D -m 0755 "${src}/builds/hume.check"                           "${o}/opt/bankonme/builds/hume.check"

{
    echo "# overlay files vendored from bankonOS (github.com/cryptoAGI/bankonOS)"
    echo "bankonos_commit=$(git -C "${src}" rev-parse HEAD)"
    echo "bankonos_dirty=$(git -C "${src}" diff --quiet HEAD -- builds && echo no || echo yes)"
    echo "synced=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ( cd "${o}" && find usr/local etc/default etc/init.d/bankon-amnesia opt -type f | sort | xargs sha256sum )
} > "${here}/vendor.lock"
echo "overlay synced from $(git -C "${src}" rev-parse --short HEAD) — see vendor.lock"
