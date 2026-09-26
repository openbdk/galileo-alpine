# galileo-alpine

**Galileo Alpine is the ISO distributor for the Open Blockchain Development Kit.** It is a bootable
Alpine Linux image that runs entirely from RAM. From it you can prepare a machine for
[openbdk/builder](https://github.com/openbdk/builder) and for the bankonOS build lines, including
Bitcoin Core and Foundry on musl.

It is the Alpine side of [bankonOS](https://github.com/cryptoAGI/bankonOS), Build G "Galileo". It is
built the way Alpine builds its own ISOs: aports' `mkimage.sh` with a `galileo` profile. It is not a
remastered image.

## Boot sequence

```
firmware ─▶ syslinux (BIOS) / GRUB (EFI)      console on screen and serial ttyS0 115200
        ─▶ linux-lts + initramfs              init_on_free=1 slab_nomerge page_alloc.shuffle=1
        ─▶ Alpine init: modloop, root = tmpfs (diskless)
        ─▶ apks from the ISO into RAM          /etc/apk/world — no network needed
        ─▶ galileo.apkovl.tar.gz applied       overlay/ (this repo)
        ─▶ OpenRC
             sysinit   devfs dmesg mdev hwdrivers modloop
             boot      … bankon-amnesia        zram swap, RAM vault /run/bankon-vault, no core dumps
             default   networking (DHCP) galileo-firstboot
                       openbdk=1 on the kernel line → openbdk-bootstrap runs too
        ─▶ login: root (tty1–6, ttyS0)
   shutdown ─▶ bankon-amnesia stop                shred the RAM vault, reset zram, drop caches
```

Nothing is written to any disk unless you run `lbu commit`.

## What openBDK's basher.sh did, and what this does instead

`basher.sh` prepares an Alpine machine for `openbdk.install`: it installs bash and makes it the login
shell, sets up doas and creates the apk cache at `/etc/apk/bdkcache`. It cannot run during boot. It
needs doas or sudo *before* it can install them, and it ends with `exec bash`.

`openbdk-bootstrap` does the same work unattended:
- bash and doas are already on the ISO, with a `wheel` rule;
- the apk cache goes on the boot medium when that is writable, so it survives a diskless reboot.

`openbdk.install` then runs unchanged. Two notes:
- Its Foundry step uses `foundryup`, which fetches glibc binaries that do not run on Alpine. Use
  `chomsky.build foundry`, which installs Foundry's official musl build, pinned by sha256.
- openbdk/builder is private, so the ISO does not carry it. Clone it with your credentials.

## On the ISO

- **bankon-ram:** RAM status, zram, compression and squashfs tests, CPU and memory benchmark, network
  diagnostics with the Tails checks, and shred/wipe.
- **bankon-amnesia:** amnesia as an OpenRC service.
- **Chomsky build line** (`/opt/bankonme/builds`):
  - Bitcoin Core: `apk add bitcoin bitcoin-cli` installs it offline from the ISO; `conf` then writes a
    read-only AION RPC user.
  - Foundry: installed from its musl release. This needs the network.
- **hume.check:** records what is installed.
- **Tools:** tor, torsocks, cryptsetup, macchanger, nftables, net-tools, iproute2, tcpdump, mtr,
  ethtool, stress-ng, sysbench, zstd, lz4, squashfs-tools.

## Build

```sh
./sync-overlay.sh /path/to/bankonOS     # refresh the vendored parts (writes vendor.lock)
./build.sh 0.1.0                        # docker or podman; → dist/*.iso, release/0.1.0/
./test/run-boot-test.sh dist/galileo-alpine-0.1.0-x86_64.iso
```

The boot test starts the ISO under KVM with **no network device**, logs in on the serial console and
checks the following: diskless root, amnesia, zram, bankon-ram, openbdk-bootstrap, an offline install
of bitcoind from the ISO, and `init_on_free=1`.

## Write to a USB stick

```sh
sha256sum -c galileo-alpine-0.1.0-x86_64.iso.sha256
dd if=galileo-alpine-0.1.0-x86_64.iso of=/dev/sdX bs=4M conv=fsync status=progress
```

## License

- The scripts and overlay in this repository are GPL-3.0-or-later, per openBDK's rule for its
  Alpine-based infrastructure.
- The ISO redistributes Alpine Linux packages under their own licenses. Their sources are in
  [aports](https://gitlab.alpinelinux.org/alpine/aports), at the commit recorded in each release's
  `MANIFEST.json`.
