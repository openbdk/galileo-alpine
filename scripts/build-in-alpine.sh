#!/bin/sh
# Runs inside alpine:3.24 (see ../build.sh). Builds the ISO with aports'
# mkimage.sh and the galileo profile, then writes release/<version>/.
set -eu
: "${VERSION:?}" "${ALPINE_BRANCH:?}" "${APORTS_REF:?}"
cd /src

apk add -q alpine-sdk alpine-conf syslinux xorriso squashfs-tools grub grub-efi mtools dosfstools git
# the mounted trees belong to the host user; let git read them for the manifest
git config --global --add safe.directory "*"

# aports scripts, pinned to a commit of the release branch
if [ ! -d /work/aports/.git ]; then
    git clone -q --filter=blob:none --no-checkout https://gitlab.alpinelinux.org/alpine/aports.git /work/aports
fi
git -C /work/aports fetch -q --depth 1 origin "$APORTS_REF"
git -C /work/aports -c advice.detachedHead=false checkout -q FETCH_HEAD -- scripts
cp profile/mkimg.galileo.sh profile/genapkovl-galileo.sh /work/aports/scripts/

# mkimage signs the ISO's apk index with a throwaway key; its public half
# rides on the ISO so apk trusts the ISO repository and nothing else new.
adduser -D build 2>/dev/null || true
addgroup build abuild 2>/dev/null || true
su build -c 'abuild-keygen -n -a' >/dev/null 2>&1
cp /home/build/.abuild/*.rsa.pub /etc/apk/keys/

mkdir -p /work/iso /work/cache
# mkimage caches the apkovl section keyed on the generator script alone, so an
# overlay change would silently reuse the old overlay: always rebuild it.
rm -rf /work/cache/apkovl_* /work/iso/*
chown -R build /work
export GALILEO_OVERLAY=/src/overlay
su build -c "cd /work/aports/scripts && GALILEO_OVERLAY=$GALILEO_OVERLAY sh mkimage.sh \
    --tag $ALPINE_BRANCH --outdir /work/iso --workdir /work/cache --arch x86_64 --profile galileo \
    --repository https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/main \
    --repository https://dl-cdn.alpinelinux.org/alpine/$ALPINE_BRANCH/community"

iso=$(ls /work/iso/alpine-galileo-*-x86_64.iso | head -1)
[ -f "$iso" ] || { echo "no ISO produced"; exit 1; }
out="/src/release/$VERSION"
mkdir -p "$out"
name="galileo-alpine-$VERSION-x86_64.iso"
cp "$iso" "/out/$name"
( cd /out && sha256sum "$name" > "$name.sha256" && sha512sum "$name" > "$name.sha512" )
cp "/out/$name.sha256" "/out/$name.sha512" "$out/"

# manifest: what is on the ISO, exactly
xorriso -osirrox on -indev "/out/$name" -extract /apks /tmp/apks >/dev/null 2>&1
{
    echo "{"
    echo "  \"version\": \"$VERSION\","
    echo "  \"alpine\": \"$ALPINE_BRANCH\","
    echo "  \"aports_commit\": \"$(git -C /work/aports rev-parse FETCH_HEAD)\","
    echo "  \"built\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
    echo "  \"iso\": \"$name\","
    echo "  \"sha256\": \"$(cut -d' ' -f1 "/out/$name.sha256")\","
    echo "  \"size_bytes\": $(stat -c %s "/out/$name"),"
    echo "  \"galileo_commit\": \"$(git -C /src rev-parse HEAD 2>/dev/null || echo unknown)\","
    echo "  \"packages\": ["
    find /tmp/apks -name '*.apk' | sed 's#.*/##; s#\.apk$##' | sort | sed 's/.*/    "&"/' | paste -sd, - | sed 's/,/,\n/g'
    echo "  ]"
    echo "}"
} > "$out/MANIFEST.json"
cp /src/vendor.lock "$out/vendor.lock"
chown -R "$HOST_UID:$HOST_GID" "$out" /out 2>/dev/null || true
echo "built $name ($(du -h "/out/$name" | cut -f1))"
