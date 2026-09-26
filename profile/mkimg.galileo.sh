# mkimg.galileo.sh — aports mkimage profile: Galileo Alpine (openBDK)
#
# The stock Alpine "standard" ISO, plus what a RAM-only bankonOS/openBDK
# node needs, all on the ISO so it boots and provisions offline. Booted,
# Alpine's init runs diskless: the root is a tmpfs, the apks below are
# installed into RAM from the ISO, and the overlay (genapkovl-galileo.sh)
# is applied on top. Nothing is written to any disk unless `lbu commit`.

profile_galileo() {
	profile_standard
	title="Galileo Alpine"
	desc="bankonOS Galileo on Alpine, for openBDK.
		RAM-only (diskless), amnesic, serial console.
		Bitcoin Core and Foundry via the Chomsky build line."
	profile_abbrev="galileo"
	image_ext="iso"
	arch="x86_64"
	output_format="iso"
	hostname="galileo"
	# serial console as well as the screen (headless boxes, VMs);
	# init_on_free=1 zeroes every freed page (amnesia at the kernel level)
	syslinux_serial="0 115200"
	kernel_cmdline="console=tty0 console=ttyS0,115200 init_on_free=1 slab_nomerge page_alloc.shuffle=1"
	apks="$apks
		bash coreutils util-linux util-linux-misc procps-ng findutils grep sed gawk
		doas shadow git curl jq ca-certificates
		zram-init zstd lz4 xz bzip2 lzop squashfs-tools
		stress-ng sysbench openssl
		net-tools iproute2 iputils traceroute mtr ethtool bind-tools tcpdump nftables
		tor torsocks cryptsetup macchanger
		bitcoin bitcoin-cli
		python3 aria2
		"
	apkovl="genapkovl-galileo.sh"
}
