#!/bin/bash
# Bootstrap installer for optiplex-fan-control.
#
#   curl -fsSL https://raw.githubusercontent.com/despotix/dell-mff-fan-controller/main/get.sh | sudo bash
#   curl -fsSL .../get.sh | sudo bash -s -- -y        # non-interactive
#
# Fetches the repository as a tarball (no git needed on the target machine) and
# hands off to install.sh, passing through any arguments.
#
# Override the source with FANCTL_REPO=owner/name and FANCTL_REF=branch-or-tag.
set -euo pipefail

REPO="${FANCTL_REPO:-despotix/dell-mff-fan-controller}"
REF="${FANCTL_REF:-main}"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "This installer needs root. Pipe it into 'sudo bash', not 'bash'." >&2
    exit 1
fi

for cmd in curl tar; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "Missing required command: $cmd" >&2; exit 1; }
done

TMPDIR_FANCTL=$(mktemp -d)
trap 'rm -rf "$TMPDIR_FANCTL"' EXIT

URL="https://codeload.github.com/${REPO}/tar.gz/${REF}"
echo "Fetching ${REPO}@${REF}..."
if ! curl -fsSL "$URL" | tar -xz -C "$TMPDIR_FANCTL" --strip-components=1; then
    echo "Could not download $URL" >&2
    echo "Check the repository name, the ref, and your network." >&2
    exit 1
fi

if [ ! -f "$TMPDIR_FANCTL/install.sh" ]; then
    echo "Downloaded archive has no install.sh — wrong repository?" >&2
    exit 1
fi

chmod +x "$TMPDIR_FANCTL"/*.sh
# Not exec: the trap above still has to clean the temporary directory up.
bash "$TMPDIR_FANCTL/install.sh" "$@"
