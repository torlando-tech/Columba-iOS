# support/ — Python embedding setup scripts

These scripts populate the gitignored `Frameworks/Python.xcframework/` and
`wheels-iphoneos/` + `wheels-iphonesimulator/` directories on every fresh clone.

## One-time setup on a new machine

```bash
support/fetch-python.sh    # ~110 MB — BeeWare's Python-Apple-support 3.13-b13
support/fetch-wheels.sh    # ~33 MB total — iOS wheels for rns, lxmf, cryptography, cffi, pyserial
```

After both succeed:
- `Frameworks/Python.xcframework/` has the iOS CPython binary + stdlib
- `wheels-iphonesimulator/` has the simulator-arch wheels
- `wheels-iphoneos/` has the device-arch wheels

The Xcode `install_python` build phase (in the ColumbaApp target) consumes
all three at build time, copying the stdlib into `<app>/python/lib/` and
processing each `.so` extension module into a per-module `.framework` so iOS
codesigning is happy.

## Pinned versions

| Component               | Source                                                              | Version              |
|-------------------------|---------------------------------------------------------------------|----------------------|
| Python-Apple-support    | github.com/beeware/Python-Apple-support                             | 3.13-b13             |
| CPython                 | bundled                                                             | 3.13.11              |
| OpenSSL                 | bundled                                                             | 3.0.18-1             |
| rns                     | PyPI                                                                | latest at fetch time |
| lxmf                    | PyPI                                                                | latest at fetch time |
| cryptography (iOS)      | BeeWare anaconda channel (pypi.anaconda.org/beeware/simple)         | 47.0.0 (pinned)      |
| cffi (iOS)              | BeeWare anaconda channel                                            | 2.0.0 (pinned)       |
| pyserial                | PyPI (pure Python)                                                  | latest at fetch time |

`msgpack` is **intentionally not installed** — RNS uses its vendored pure-Python
`RNS.vendor.umsgpack`. Installing the binary `msgpack` from PyPI pulls a macOS
wheel that won't load on iOS.

## Bumping the Python build

Edit `PY_VERSION` / `PY_BUILD` in `support/fetch-python.sh`, then re-run it.
The script removes the existing `Python.xcframework/` before extracting.

If the Python *minor* version bumps (3.13 → 3.14), the wheel platform tags
in `support/fetch-wheels.sh` need to bump too (`cp313` → `cp314`).

## Why these are scripts, not vendored

The xcframework is ~110 MB and the wheels are ~33 MB combined. Vendoring 140 MB
of binaries in git would make every clone slow, blow up history, and make
license review confusing. Fetch scripts with pinned versions give the same
reproducibility without the cost.
