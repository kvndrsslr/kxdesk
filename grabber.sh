#!/usr/bin/env bash
#
# The root daemon that tap-hold rules need.
#
# `.remap a [device builtin] { tap: a, hold: lshift }` cannot be done from an event
# tap. Deciding tap-versus-hold means swallowing the key before anyone else sees
# it, and delivering the hold means injecting a modifier — which takes seizing the
# keyboard (root, IOHIDManager) and a virtual HID device to type through. That is
# upstream's `kxdesk-grabber`, built from the same pinned source as the engine and
# installed here as its own LaunchDaemon: nothing else about kxdesk needs root, and
# the seize is device-scoped to the (vendor, product) a rule names.
#
#   sudo ./grabber.sh install     # write the plist and start it
#   sudo ./grabber.sh uninstall   # stop it and remove the plist
#        ./grabber.sh status      # is it up, where does it log
#
# Stopping it releases the keyboard: the seize lives only as long as the process.
set -euo pipefail

label=org.kdressler.kxdesk.grabber
plist=/Library/LaunchDaemons/$label.plist
program=/opt/homebrew/opt/kxdesk/bin/kxdesk-grabber
log=/opt/homebrew/var/log/kxdesk-grabber.log
# The daemon half of the pqrs virtual-HID package: the grabber types through it,
# and it arrives with the driver extension rather than with this repo.
vhidd_server="/Library/Application Support/org.pqrs/tmp/rootonly/vhidd_server"

require_root() {
    [ "$(id -u)" = 0 ] || {
        echo "grabber: $1 needs root: sudo $0 $1" >&2
        exit 1
    }
}

case "${1:-status}" in
install)
    require_root install
    [ -x "$program" ] || {
        echo "grabber: $program is not installed" >&2
        exit 1
    }
    if ! compgen -G "$vhidd_server/*.sock" >/dev/null; then
        echo "grabber: the virtual HID daemon is not running - it is what the" >&2
        echo "         grabber types through. Install it, then run this again:" >&2
        echo "           brew install --cask kvndrsslr/formulae/kxdext" >&2
        exit 1
    fi
    cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$program</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <!-- A daemon that died is restarted, but not in a tight loop. -->
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>$log</string>
    <key>StandardErrorPath</key>
    <string>$log</string>
</dict>
</plist>
EOF
    launchctl bootout system/"$label" 2>/dev/null || true
    launchctl bootstrap system "$plist"
    echo "grabber: installed $label ($program)"
    ;;
uninstall)
    require_root uninstall
    launchctl bootout system/"$label" 2>/dev/null || true
    rm -f "$plist"
    echo "grabber: removed $label"
    ;;
status)
    if pgrep -qx kxdesk-grabber; then
        echo "grabber: running"
    else
        echo "grabber: not running"
    fi
    if [ -f "$plist" ]; then
        echo "grabber: plist $plist"
    else
        echo "grabber: no plist (not installed)"
    fi
    echo "grabber: log $log"
    ;;
*)
    echo "usage: $0 [install|uninstall|status]" >&2
    exit 2
    ;;
esac
