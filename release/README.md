# release/

One folder per released version. The ISO files are attached to the matching
[GitHub Release](https://github.com/openbdk/galileo-alpine/releases); only their
fingerprints live in git.

| File | What |
|------|------|
| `galileo-alpine-VERSION-x86_64.iso.sha256` / `.sha512` | checksums of the release ISO |
| `MANIFEST.json` | Alpine branch, the pinned aports commit, the galileo-alpine commit, ISO size and hash, and every apk on the ISO |
| `vendor.lock` | the bankonOS commit the overlay was taken from, with a sha256 for each vendored file |
| `BOOT-TEST.txt` | the result of `test/boot-test.py` against this exact ISO |

Verify a download:

```sh
sha256sum -c galileo-alpine-0.1.0-x86_64.iso.sha256
```

Reproduce a release: check out the tag, then run `./build.sh VERSION`. The aports commit is pinned in
`build.sh`. The apks come from the Alpine mirrors at build time, so a rebuild matches the manifest's
package list but is not byte-identical.
