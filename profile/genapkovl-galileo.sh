#!/bin/sh -e
# genapkovl-galileo.sh HOSTNAME — the overlay Alpine's init applies at boot.
# Builds on aports' genapkovl-dhcp.sh (runlevels, DHCP) and adds the
# Galileo files from $GALILEO_OVERLAY (this repo's overlay/).

HOSTNAME="$1"
[ -n "$HOSTNAME" ] || { echo "usage: $0 hostname"; exit 1; }
[ -d "${GALILEO_OVERLAY:-}" ] || { echo "GALILEO_OVERLAY not set to the overlay directory"; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

rc_add() { mkdir -p "$tmp/etc/runlevels/$2"; ln -sf "/etc/init.d/$1" "$tmp/etc/runlevels/$2/$1"; }

# the Galileo files (owned by root, modes as in the repo)
cp -a "$GALILEO_OVERLAY"/. "$tmp"/
chown -R 0:0 "$tmp"

echo "$HOSTNAME" > "$tmp/etc/hostname"

mkdir -p "$tmp/etc/network"
cat > "$tmp/etc/network/interfaces" <<IFACES
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp
IFACES

# installed into RAM from the ISO at every boot (must be in the profile's apks)
cat > "$tmp/etc/apk/world" <<WORLD
alpine-base
bash
coreutils
util-linux
util-linux-misc
procps-ng
doas
shadow
git
curl
jq
zram-init
zstd
lz4
xz
squashfs-tools
stress-ng
sysbench
openssl
net-tools
iproute2
iputils
traceroute
mtr
ethtool
bind-tools
tcpdump
nftables
tor
torsocks
cryptsetup
macchanger
WORLD

rc_add devfs sysinit
rc_add dmesg sysinit
rc_add mdev sysinit
rc_add hwdrivers sysinit
rc_add modloop sysinit

rc_add hwclock boot
rc_add modules boot
rc_add sysctl boot
rc_add hostname boot
rc_add bootmisc boot
rc_add syslog boot
rc_add bankon-amnesia boot

rc_add networking default
rc_add galileo-firstboot default

rc_add mount-ro shutdown
rc_add killprocs shutdown
rc_add savecache shutdown

tar -c -C "$tmp" . | gzip -9n > "$HOSTNAME.apkovl.tar.gz"
