#!/usr/bin/env bash
# build.sh VERSION — build galileo-alpine-VERSION-x86_64.iso in an alpine
# container (podman or docker). Output: dist/ (ISO + checksums) and
# release/VERSION/ (checksums, MANIFEST.json, vendor.lock) for git.
set -euo pipefail
VERSION="${1:?usage: build.sh VERSION (e.g. 0.1.0)}"
ALPINE_BRANCH="${ALPINE_BRANCH:-v3.24}"
APORTS_REF="${APORTS_REF:-de51ebac9230046e58032d397ee1f0a10a069627}"   # 3.24-stable, 2026-09-25
here="$(cd "$(dirname "$0")" && pwd)"
# podman preferred, docker as the fallback
rt="$(command -v podman || command -v docker)" || { echo "podman or docker required" >&2; exit 1; }
mkdir -p "${here}/dist"
"$rt" run --rm \
    -v "${here}:/src" -v "${here}/dist:/out" -v galileo-alpine-work:/work \
    -e VERSION="$VERSION" -e ALPINE_BRANCH="$ALPINE_BRANCH" -e APORTS_REF="$APORTS_REF" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    docker.io/library/alpine:3.24 sh /src/scripts/build-in-alpine.sh
