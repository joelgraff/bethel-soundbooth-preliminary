#!/bin/bash
# install-usb-reset-helper.sh — install the privileged PreSonus USB reset
# helper and its narrowly-scoped sudoers grant.
#
# Run this ONCE, as root:
#     sudo audio-routing/scripts/install-usb-reset-helper.sh
#
# It is idempotent — safe to re-run after editing the source files in the
# repo, which is how you deploy a change to the helper.
#
# Everything here is deliberately fail-closed. The sudoers fragment is
# syntax-checked with `visudo -cf` in a temporary location BEFORE it is moved
# into /etc/sudoers.d/, because a malformed file there locks every user on
# this machine out of sudo — and this box's whole problem is that nobody is
# physically present to fix things.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_HELPER="${REPO_DIR}/audio-routing/scripts/presonus-usb-reset"
SRC_SUDOERS="${REPO_DIR}/audio-routing/sudoers.d/presonus-usb-reset"
DST_HELPER="/usr/local/sbin/presonus-usb-reset"
DST_SUDOERS="/etc/sudoers.d/presonus-usb-reset"
GRANT_USER="soundbooth"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "must be run as root: sudo $0"
[[ -f "$SRC_HELPER"  ]] || die "missing source helper: $SRC_HELPER"
[[ -f "$SRC_SUDOERS" ]] || die "missing source sudoers fragment: $SRC_SUDOERS"

echo "==> installing helper to ${DST_HELPER}"
install -o root -g root -m 0755 "$SRC_HELPER" "$DST_HELPER"
# Belt and braces: the sudoers grant is only safe while this file is not
# writable by the user it is granted to.
if [[ -w "$DST_HELPER" ]] && [[ "$(stat -c '%U' "$DST_HELPER")" != "root" ]]; then
    die "refusing to continue: ${DST_HELPER} is not root-owned"
fi
perms="$(stat -c '%a %U %G' "$DST_HELPER")"
[[ "$perms" == "755 root root" ]] || die "unexpected perms on ${DST_HELPER}: ${perms}"
echo "    ok: ${perms}"

echo "==> syntax-checking the sudoers fragment before installing it"
TMP_SUDOERS="$(mktemp)"
trap 'rm -f "$TMP_SUDOERS"' EXIT
install -o root -g root -m 0440 "$SRC_SUDOERS" "$TMP_SUDOERS"
if ! visudo -cf "$TMP_SUDOERS"; then
    die "sudoers fragment FAILED validation — nothing installed, sudo untouched"
fi

echo "==> installing sudoers fragment to ${DST_SUDOERS}"
install -o root -g root -m 0440 "$TMP_SUDOERS" "$DST_SUDOERS"

echo "==> re-validating the whole sudoers configuration"
if ! visudo -c >/dev/null; then
    rm -f "$DST_SUDOERS"
    die "full sudoers validation failed — fragment REMOVED, sudo left as it was"
fi
echo "    ok"

echo "==> verifying the grant resolves for ${GRANT_USER}"
if sudo -u "$GRANT_USER" sudo -n -l "$DST_HELPER" >/dev/null 2>&1; then
    echo "    ok: ${GRANT_USER} may run ${DST_HELPER} without a password"
else
    echo "    WARNING: grant did not resolve as expected; check 'sudo -n -l' as ${GRANT_USER}"
fi

cat <<EOF

Installed.

Test it WITHOUT touching the board:
    sudo -n /usr/local/sbin/presonus-usb-reset --probe

That reports whether the device is currently responding and takes no action.
Then, for a real test, run the unprivileged orchestrator:
    ~/bin/presonus-recover.sh --dry-run     # shows the plan, changes nothing
    ~/bin/presonus-recover.sh               # stop bridge, reset, restart, verify

To deploy a later edit to the helper, edit the copy in the repo and re-run
this installer.
EOF
