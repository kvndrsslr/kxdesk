#!/usr/bin/env sh
#
# Ship what is committed to this machine: push it, move the brew HEAD build onto
# it, and restart the daemon that is serving the bar from the old one.
#
# The order is forced. The formula builds from `main` on GitHub, not from this
# checkout, so the push has to land before `--fetch-HEAD` can see the commit; and
# the running daemon only becomes the new binary when the service restarts, which
# is why the push alone changes nothing here.
#
# Two things are deliberately not done here, because they are not wanted every
# time:
#
#   * `brew services restart kxsketchybar` - a bar process keeps its items, their
#     subscriptions and every event it has registered for as long as it lives, so
#     a configuration that retires one of either needs that restart to take
#     effect. Nothing is removed until then.
#   * `kxdesk wm refresh-signals` - a changed signal table reaches yabai only when
#     something writes it: this command, or the `apply-settings` in `~/.yabairc`
#     that runs when yabai starts.
set -eu

cd "$(dirname "$0")"

# Uncommitted work is not deployed, and saying nothing would let it look as if it
# had been: `--fetch-HEAD` builds GitHub's commit, not the working tree.
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "deploy: commit the working tree first - HEAD is what gets deployed" >&2
    exit 1
fi

git push
brew upgrade --fetch-HEAD kxdesk

# Re-sign what brew installed, with the local identity `sign.sh` keeps.
#
# The build runs inside Homebrew's sandbox, which denies the keychain, so the
# signing `zig build` does there falls back to ad-hoc - and an ad-hoc signature's
# identity is the binary's cdhash, which changes with every build. That is one
# Accessibility grant lost per deploy: the entry stays in the list, switched on,
# and authorizes nothing. Signing here, outside the sandbox, gives the bundle the
# identity that survives it.
installed=$(brew --prefix kxdesk)
bash sign.sh "$installed/kxdesk.app"
# The grabber's bundle carries the other grant - Input Monitoring, which the
# seize needs - so it is signed the same way and for the same reason.
bash sign.sh "$installed/kxdesk-grabber.app"

brew services restart kxdesk
