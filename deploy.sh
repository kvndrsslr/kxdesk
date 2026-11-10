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
#   * `kxdesk wm apply-settings` - once after an upgrade that retires yabai
#     provisioning: the sweep of the retired signals runs there, and so does the
#     `apply-settings` in `~/.yabairc` on the next yabai start.
#
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

# The restart runs the formula's service entry, which signs both bundles with
# the local identity `sign.sh` keeps before it execs the daemon: the build's own
# signature is ad-hoc inside Homebrew's sandbox, and an ad-hoc identity is the
# binary's cdhash, one lost grant per deploy.
brew services restart kxdesk
