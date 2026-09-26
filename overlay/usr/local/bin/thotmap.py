#!/usr/bin/env python3
"""thotmap.py — one pass over a file, every identity bankon-share maps it to.

  thot      thot:<sha256 hex>                     the identity (THOTpaper §2)
  cid_raw   CIDv1 raw (0x55) + sha2-256, base32   = ipfs add --cid-version 1 --raw-leaves, ≤ 256 KiB
  cid       CIDv1 UnixFS (dag-pb) for > 256 KiB    = ipfs add --cid-version 1 (raw leaves, 256 KiB
            chunks, balanced, ≤ 174 links); equals cid_raw for ≤ 256 KiB
  btih      BitTorrent v1 infohash, magnet link, and a .torrent file whose comment carries the THOT
            reference and whose url-list may carry web seeds (IPFS / Arweave gateways)

A port of ~/permanence/lib/ipld.js (same algorithm, same results — see test/). Standard library only,
streamed in 256 KiB blocks, so it runs on every bankonOS build (Debian, Devuan, Alpine) and never holds
a large file in RAM.

  thotmap.py FILE [--torrent OUT.torrent] [--webseed URL]... [--tracker URL]...   → JSON on stdout
"""

import argparse
import hashlib
import json
import os
import sys
from urllib.parse import quote

CHUNK = 262_144          # 256 KiB: kubo's default chunker and the single-block limit
MAX_LINKS = 174          # kubo balanced layout
CODEC_RAW, CODEC_DAG_PB, MH_SHA256 = 0x55, 0x70, 0x12


# ── multiformats ──────────────────────────────────────────────────────────────
def varint(n):
    out = bytearray()
    while n >= 0x80:
        out.append((n & 0x7F) | 0x80)
        n >>= 7
    out.append(n)
    return bytes(out)


def base32_lower(b):
    alphabet = "abcdefghijklmnopqrstuvwxyz234567"
    bits = value = 0
    out = []
    for byte in b:
        value = (value << 8) | byte
        bits += 8
        while bits >= 5:
            out.append(alphabet[(value >> (bits - 5)) & 31])
            bits -= 5
    if bits:
        out.append(alphabet[(value << (5 - bits)) & 31])
    return "".join(out)


def multihash(data):
    return bytes([MH_SHA256, 0x20]) + hashlib.sha256(data).digest()


def cid_bytes(codec, mh):
    return b"\x01" + varint(codec) + mh


def cid_string(codec, mh):
    return "b" + base32_lower(cid_bytes(codec, mh))


# ── dag-pb + UnixFS (only the fields kubo emits) ─────────────────────────────
def pb_field(field_no, wire, payload):
    head = varint((field_no << 3) | wire)
    return head + (varint(len(payload)) + payload if wire == 2 else payload)


def pb_varint(field_no, n):
    return pb_field(field_no, 0, varint(n))


def pb_bytes(field_no, b):
    return pb_field(field_no, 2, b)


def unixfs_file(filesize, blocksizes):
    return pb_varint(1, 2) + pb_varint(3, filesize) + b"".join(pb_varint(4, s) for s in blocksizes)


def dag_pb_node(links, data):
    link_bytes = b"".join(
        pb_bytes(2, pb_bytes(1, l["cid"]) + pb_bytes(2, b"") + pb_varint(3, l["tsize"])) for l in links
    )
    return link_bytes + pb_bytes(1, data)


def fold(level):
    """Balanced layout: group ≤ MAX_LINKS children per node until one root remains."""
    while len(level) > 1:
        nxt = []
        for i in range(0, len(level), MAX_LINKS):
            group = level[i:i + MAX_LINKS]
            filesize = sum(l["filesize"] for l in group)
            node = dag_pb_node(group, unixfs_file(filesize, [l["filesize"] for l in group]))
            nxt.append({
                "cid": cid_bytes(CODEC_DAG_PB, multihash(node)),
                "tsize": len(node) + sum(l["tsize"] for l in group),
                "filesize": filesize,
            })
        level = nxt
    return level[0]["cid"]


# ── bencode (BitTorrent) ──────────────────────────────────────────────────────
def bencode(x):
    if isinstance(x, int):
        return b"i%de" % x
    if isinstance(x, str):
        x = x.encode()
    if isinstance(x, bytes):
        return b"%d:%s" % (len(x), x)
    if isinstance(x, list):
        return b"l" + b"".join(bencode(i) for i in x) + b"e"
    if isinstance(x, dict):
        items = sorted((k.encode() if isinstance(k, str) else k, v) for k, v in x.items())
        return b"d" + b"".join(bencode(k) + bencode(v) for k, v in items) + b"e"
    raise TypeError(type(x))


def piece_length_for(size):
    """≈ 1000–2000 pieces, between 256 KiB and 16 MiB (common client defaults)."""
    pl = CHUNK
    while size / pl > 2000 and pl < 16 * 1024 * 1024:
        pl *= 2
    return pl


# ── one pass ──────────────────────────────────────────────────────────────────
def identify(path):
    size = os.path.getsize(path)
    piece_len = piece_length_for(size)
    sha = hashlib.sha256()
    leaves = []
    pieces = bytearray()
    piece_buf = bytearray()
    first_block = None
    with open(path, "rb") as f:
        while True:
            block = f.read(CHUNK)
            if not block:
                break
            if first_block is None:
                first_block = block
            sha.update(block)
            leaves.append({"cid": cid_bytes(CODEC_RAW, multihash(block)), "tsize": len(block), "filesize": len(block)})
            piece_buf += block
            while len(piece_buf) >= piece_len:
                pieces += hashlib.sha1(piece_buf[:piece_len]).digest()
                del piece_buf[:piece_len]
    if piece_buf or size == 0:
        pieces += hashlib.sha1(bytes(piece_buf)).digest()

    digest = sha.digest()
    raw = cid_string(CODEC_RAW, bytes([MH_SHA256, 0x20]) + digest)
    single = size <= CHUNK
    cid = raw if single else "b" + base32_lower(fold(leaves))
    return {
        "bytes": size, "sha256": digest.hex(), "thot": "thot:" + digest.hex(),
        "cid_raw": raw, "cid": cid, "cid_codec": "raw" if single else "dag-pb",
        "_torrent": {"piece_length": piece_len, "pieces": bytes(pieces)},
    }


def torrent(ident, name, webseeds, trackers):
    info = {"name": name, "length": ident["bytes"],
            "piece length": ident["_torrent"]["piece_length"], "pieces": ident["_torrent"]["pieces"]}
    meta = {"info": info, "comment": ident["thot"], "created by": "bankon-share"}
    if webseeds:
        meta["url-list"] = webseeds
    if trackers:
        meta["announce"] = trackers[0]
        meta["announce-list"] = [[t] for t in trackers]
    btih = hashlib.sha1(bencode(info)).hexdigest()
    magnet = f"magnet:?xt=urn:btih:{btih}&dn={quote(name)}&xl={ident['bytes']}"
    magnet += "".join(f"&tr={quote(t, safe='')}" for t in trackers)
    magnet += "".join(f"&ws={quote(w, safe='')}" for w in webseeds)
    return btih, magnet, bencode(meta)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("file")
    ap.add_argument("--torrent", help="write the .torrent here")
    ap.add_argument("--name", help="name inside the torrent (default: file name)")
    ap.add_argument("--webseed", action="append", default=[], help="HTTP(S) URL serving the same bytes (BEP 19)")
    ap.add_argument("--tracker", action="append", default=[], help="tracker URL (default: trackerless, DHT)")
    a = ap.parse_args()

    ident = identify(a.file)
    btih, magnet, meta = torrent(ident, a.name or os.path.basename(a.file), a.webseed, a.tracker)
    if a.torrent:
        with open(a.torrent, "wb") as f:
            f.write(meta)
    out = {k: v for k, v in ident.items() if not k.startswith("_")}
    out.update({"btih": btih, "magnet": magnet, "torrent": a.torrent,
                "piece_length": ident["_torrent"]["piece_length"], "webseeds": a.webseed, "trackers": a.tracker})
    json.dump(out, sys.stdout, indent=2)
    print()


if __name__ == "__main__":
    main()
