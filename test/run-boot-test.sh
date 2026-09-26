#!/usr/bin/env bash
# run-boot-test.sh ISO — run test/boot-test.py in a throwaway Debian container
# with /dev/kvm, so QEMU does not have to be installed on the host.
set -euo pipefail
iso="$(readlink -f "${1:?usage: run-boot-test.sh ISO}")"
here="$(cd "$(dirname "$0")" && pwd)"
rt="$(command -v docker || command -v podman)"   # rootless podman cannot keep abuild-sudo setuid
"$rt" run --rm -m 2500m --device /dev/kvm -v "$iso:/iso.iso:ro" -v "$here:/t:ro" docker.io/library/debian:trixie bash -c '
  apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends qemu-system-x86 python3 >/dev/null 2>&1
  python3 /t/boot-test.py /iso.iso'
