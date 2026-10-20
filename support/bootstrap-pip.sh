#!/usr/bin/env bash
# Bootstrap a usable pip into a fresh, pip-less venv. Sourced by
# support/fetch-wheels.sh (also runnable standalone - Tests/static/
# test_fetch_wheels_pip_bootstrap.py drives it with stubbed python3/curl).
#
# Sets in the calling shell:
#   PIP_VENV   temp venv dir (removed by an EXIT trap registered here)
#   PIP_PYTHON interpreter path with a runnable pip >= 25
#
# Why not just use the interpreter's ensurepip pip: it can be too old for the
# interpreter ITSELF (Python 3.15 removed typing.no_type_check_decorator, which
# pip <= 25.1.x vendored typing_extensions imports at startup - pip crashes
# before it can upgrade itself) or too old for PEP 621 metadata. So the venv is
# created WITHOUT pip and pip is bootstrapped explicitly, then the pinned
# packaging toolchain is installed with it so ble-reticulum cannot silently
# become an empty UNKNOWN-0.0.0 distribution.
#
# The bootstrap SOURCE depends on the HOST interpreter, because macOS system
# python3 is 3.9.6 (Xcode Cloud runners included) and the rolling
# bootstrap.pypa.io/pip/pip.pyz tracks the LATEST pip, which requires
# >= 3.10 - running it under 3.9 aborts with "This version of pip does not
# support python 3.9" and fails every fresh-clone build (post-clone hook).
# So: >= 3.10 hosts get the rolling zipapp + the pip==26.2.1 pin (3.15
# capable, proven on the runner); older hosts get pypa's per-version
# get-pip channel, which serves the last pip that supports that interpreter
# (25.x on 3.9 - new enough for PEP 621 metadata and the cross-platform
# --target installs fetch-wheels.sh performs).

PIP_VENV="$(mktemp -d "${TMPDIR:-/tmp}/columba-wheel-pip.XXXXXX")"
trap 'rm -rf "$PIP_VENV"' EXIT
python3 -m venv --without-pip "$PIP_VENV"
PIP_PYTHON="$PIP_VENV/bin/python"
# Xcode Cloud intermittently resets long downloads; --fail keeps an HTTP
# error page from being saved as the bootstrap file (Python would then "run"
# the error page), and the bounded retries match fetch-python.sh's convention.
CURL=(curl --fail --silent --show-error --location
      --retry 5 --retry-all-errors --retry-delay 2
      --retry-max-time 600 --connect-timeout 30)
if "$PIP_PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)'; then
    "${CURL[@]}" --output "$PIP_VENV/pip.pyz" https://bootstrap.pypa.io/pip/pip.pyz
    "$PIP_PYTHON" "$PIP_VENV/pip.pyz" install --quiet \
        "pip==26.2.1" "setuptools==80.9.0" "wheel==0.45.1"
else
    HOST_SERIES="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
    echo "==> Host python3 is $HOST_SERIES (< 3.10): bootstrapping pip from the $HOST_SERIES get-pip channel"
    "${CURL[@]}" --output "$PIP_VENV/get-pip.py" \
        "https://bootstrap.pypa.io/pip/${HOST_SERIES}/get-pip.py"
    "$PIP_PYTHON" "$PIP_VENV/get-pip.py" --quiet \
        "setuptools==80.9.0" "wheel==0.45.1"
fi
# Functional floor, not an exact pin: pip must be >= 25 (PEP 621 metadata +
# the cross-platform flags fetch-wheels.sh uses) and actually runnable.
"$PIP_PYTHON" -m pip --version | grep -qE "pip (2[5-9]|[3-9][0-9])\."
