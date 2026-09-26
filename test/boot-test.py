#!/usr/bin/env python3
"""boot-test.py ISO — boot Galileo Alpine under QEMU/KVM, log in on the serial
console, and check the running system. Exit 0 only if every check passes.

Checks (each is a command whose output must match):
  diskless        root filesystem is a tmpfs (Alpine diskless mode)
  amnesia         bankon-amnesia service started (RAM vault mounted, core dumps off)
  zram            compressed swap in RAM is active
  bankon-ram      the toolkit runs
  bootstrap       openbdk-bootstrap completes (bash, doas, apk cache)
  offline-apk     bitcoind installs from the ISO with networking unplugged
"""
import os, re, socket, subprocess, sys, time

iso = sys.argv[1]
sock_path = "/tmp/galileo-serial.sock"
if os.path.exists(sock_path):
    os.unlink(sock_path)

qemu = subprocess.Popen([
    "qemu-system-x86_64", "-enable-kvm", "-cpu", "host", "-m", "1536", "-smp", "2",
    "-cdrom", iso, "-boot", "d", "-display", "none",
    "-chardev", f"socket,id=s0,path={sock_path},server=on,wait=off", "-serial", "chardev:s0",
    # no network device: everything must come from the ISO
    "-nic", "none", "-no-reboot",
], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

for _ in range(50):
    if os.path.exists(sock_path):
        break
    time.sleep(0.2)
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)
s.settimeout(1)
log = open("/tmp/galileo-boot.log", "w")
buf = ""

def read_until(pattern, timeout):
    global buf
    end = time.time() + timeout
    while time.time() < end:
        try:
            chunk = s.recv(4096).decode(errors="replace")
            buf += chunk
            log.write(chunk); log.flush()
        except socket.timeout:
            pass
        m = re.search(pattern, buf)
        if m:
            out = buf[:m.end()]
            buf = buf[m.end():]
            return out
    raise TimeoutError(f"waited {timeout}s for {pattern!r}")

def run(cmd, timeout=120):
    s.sendall((f"{cmd}; echo __RC=$?__\n").encode())
    out = read_until(r"__RC=\d+__", timeout)
    rc = int(re.search(r"__RC=(\d+)__", out).group(1))
    read_until(r"# $", 10)
    return rc, out

results = []
def check(name, cmd, must, timeout=120):
    try:
        rc, out = run(cmd, timeout)
        ok = rc == 0 and re.search(must, out) is not None
    except TimeoutError as e:
        ok, out = False, str(e)
    results.append((name, ok))
    print(f"  {'PASS' if ok else 'FAIL'}  {name}")
    if not ok:
        print("        " + out.strip().replace("\n", "\n        ")[-600:])

try:
    read_until(r"login: ", 240)
    s.sendall(b"root\n")
    read_until(r"# $", 30)
    run("stty cols 200; export PS1='# '")
    check("diskless", "awk '$2==\"/\"{print $3}' /proc/mounts", r"tmpfs")
    check("amnesia", "bankon-amnesia status", r"RAM vault mounted\s+yes[\s\S]*core dumps off\s+yes")
    check("zram", "grep zram /proc/swaps", r"/dev/zram")
    check("bankon-ram", "bankon-ram status | head -20", r"diskless\s+yes")
    check("bootstrap", "openbdk-bootstrap root", r"ready for openbdk/builder")
    check("offline-apk", "apk add -q bitcoin bitcoin-cli && bitcoind -version | head -1", r"Bitcoin Core", 300)
    check("init_on_free", "cat /proc/cmdline", r"init_on_free=1")
finally:
    try:
        s.sendall(b"poweroff\n")
        time.sleep(5)
    except OSError:
        pass
    qemu.kill()

failed = [n for n, ok in results if not ok]
print(f"\n{len(results) - len(failed)}/{len(results)} passed" + (f" — failed: {', '.join(failed)}" if failed else ""))
sys.exit(1 if failed or not results else 0)
