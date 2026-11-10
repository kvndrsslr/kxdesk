#!/bin/sh
#
# The daemon's launchd entry: give both bundles the machine's stable identity,
# then become the daemon.
#
# Homebrew cannot sign them where it installs them - the install step and the
# post-install steps run sandboxed, with a temporary home and only the system
# keychain in the search list - so the one process that always runs inside the
# user's session, before the daemon is exec'd, is this one.
set -eu

libexec=$(dirname "$0")
prefix=${libexec%/libexec}

# Signing is idempotent: `sign.sh` leaves a bundle that already carries the
# identity alone, so a restart that changes nothing costs one probe per bundle.
"$libexec/sign.sh" "$prefix/kxdesk.app" || true
if [ -d "$prefix/kxdesk-grabber.app" ]; then
    "$libexec/sign.sh" "$prefix/kxdesk-grabber.app" || true
fi

exec "$prefix/kxdesk.app/Contents/MacOS/kxdesk" daemon
