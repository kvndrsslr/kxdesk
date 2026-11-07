# kxdesk

A personal desktop daemon for macOS. It serves SketchyBar's item events and a
command channel over one mach port, so the bar's items are configured in Zig
instead of shell, clicks arrive as events instead of forked processes, and the
commands that the key bindings, `~/.yabairc` and the bar's config script name are
answered by one long-lived process. It also owns the keyboard: the
key bindings are skhd bindings, parsed and run in this process (see below).

It also owns the state those things share: one SQLite database at
`~/Library/Application Support/kxdesk/state.db`, reachable from outside with
`kxdesk state get|set|unset|list`.

## The command line

Every command is described once, in `src/commands.zig` — its name, its
subcommands, its arguments and its flags — and both the help and the shell
completions are drawn from that description, so neither can drift from what the
daemon actually runs:

```sh
kxdesk --help              # every command, one line each
kxdesk help <command>      # one command in full
kxdesk <command> --help    # the same, without running it
kxdesk completions zsh     # or bash
```

These are answered by the binary itself rather than the daemon, so they work
when nothing is listening.

The description is also what a request is *checked* against before it is sent or
run, so a malformed one is answered with what was expected instead of whatever
the command would have made of it:

```
$ kxdesk state set
state set: missing <key>
usage: kxdesk state set <key> [<value>] [--int] [--real] [--null]
```

The completion scripts are thin: they hand the words to `kxdesk __complete`,
which answers from the same description, so a command that is added or changed is
completed correctly without regenerating anything. That call answers with the
words alone; zsh passes `--describe` to also get what each candidate does, and
shows it beside the match. A value that only exists at runtime is completed too:
`state get` offers the keys that are actually in the store, and `wm
switch-workspace` offers the labels yabai is actually carrying (see `kxdesk wm
space-labels`). Those come from the running daemon and are simply absent when
there is not one; pressing TAB never starts it.

The script and the binary are installable separately and can therefore be out of
step, so the protocol is written to survive it: the words alone are what every
version has answered, a script that predates `--describe` still reads a clean
list, and a script that is newer than the binary asks a second time without the
flag rather than completing nothing.

The Homebrew formula installs both of them where each shell already looks —
`share/zsh/site-functions/_kxdesk` (on `$fpath` through `brew shellenv zsh`) and
`etc/bash_completion.d/kxdesk` (the `bash-completion` directory) — so a brewed
kxdesk needs nothing further. For a checkout, or any copy Homebrew did not
install, evaluate the script instead:

```sh
eval "$(kxdesk completions zsh)"      # or bash
```

Fish is not supported: it is not installed here, so its script would ship
untested.

## The key bindings: the embedded engine

The bindings live in `~/.config/kxdesk/skhdrc`, in skhd's grammar, and this daemon
runs them itself: upstream [skhd.zig](https://github.com/jackielii/skhd.zig) is
compiled into the binary (`src/hotkey.zig` hosts it), so its event tap owns the
keyboard, its parser reads the config, and a key press runs a command with no
process in between. There is no root service and no driver extension — one
Accessibility grant for `kxdesk.app` is the whole setup — and stopping the daemon
gives the keyboard back, because an event tap dies with the process that
installed it.

An action is a shell command, as in skhd. The one addition is `! ` at the start:
the rest of the line is a `kxdesk` argv line with the binary name left off, which
is the whole vocabulary — every window, space and display verb is a subcommand of
`kxdesk wm`, together with yabai's provisioning (`wm apply-settings`,
`wm refresh-rules`) — so a binding and the command
`~/.yabairc` writes are the same words:

```
hyper - t : ! term toggle btop
```

A binding is checked when it fires, against the same command description a request
from a shell is checked against, so a typo is a line in the log with the reason in
it rather than a key that does nothing. The payload a command answers with has
nobody to answer, so it is dropped.

Modes are skhd's, declared in the config, and they isolate: an untagged binding
belongs to `default` and is inert in every other mode. No binding sets the bar's
mode indicator — the engine reports the mode change and the daemon colours the
space icons from it (`op`, `wmode` and `smode` are the three colours, `default`
clears them), and a config reload resets both, which is the highlight's one reset.

```sh
kxdesk hotkey status                        # which config, and how many actions it has run
kxdesk hotkey inject "wm window-swap west"  # run a binding without pressing its keys
kxdesk hotkey reload                        # re-read the config, as saving it does
```

There is one thing the tap cannot do, and it is the internal keyboard's home-row
mods: deciding tap-versus-hold means swallowing a key before anything else sees it,
and delivering the hold means typing a modifier back. That takes a seized keyboard
(root) and a virtual HID device to type through — pqrs's Karabiner driver plus
upstream's grabber daemon. `brew` installs the binaries; one privileged command
installs both of those, pins the driver to a version and a sha256, and registers the
daemon with launchd:

```sh
sudo kxdesk grabber install     # the driver extension, the grabber daemon, then the drag
kxdesk grabber status           # both halves, the grant, and the grabber's build
```

The daemon needs one more grant than the rest of kxdesk: **Input Monitoring**, for
`kxdesk-grabber` in System Settings > Privacy & Security. Seizing a keyboard is what
tap-hold costs, and macOS refuses it to an unapproved process with
`kIOReturnNotPermitted` — which is exactly what a root LaunchDaemon cannot ask for,
because the approval dialog needs a session to appear in. That is also why the
grabber ships as a `.app`: the pane wants an app to add, and the bundle identifier
plus the signing certificate are what make the grant survive an upgrade.

An install ends with that grant, so it does not end in instructions: `install` opens
the Input Monitoring pane and a panel beside it, the app on the panel is the thing to
drag into the list, and the panel closes by itself once the grant lands — the grabber
is then restarted with it, no second password. Nothing about that is inferred from a
log: the grant is reported in the grabber's own IPC reply, because TCC answers
`IOHIDCheckAccess` only for the process that asks.

The daemon checks that half on every start, and does not ask: a grabber that answers
without the grant is a process older than the binary — `brew upgrade` replaces the
file, launchd keeps the image — so it is asked to exit and `KeepAlive` starts the new
one; an unapproved one gets the panel with the drag; a missing one gets the panel
whose Install button runs the privileged install in a terminal. The loop stops as
soon as the grabber says it may seize, and `kxdesk guide` reopens the panel when it
was dismissed.

The rules that use it live in `skhdrc` under `.device builtin { vendor: 0x0,
product: 0x0 }` — that is how the internal keyboard identifies itself — so the QMK
boards, which mod-tap in firmware, never see them.

`inject` runs the same lookup, the same check and the same command the tap runs,
which is what makes a binding testable without pressing its keys. `reload` sends
the engine the signal it already handles; saving the file does the same on its own,
because the engine watches it with FSEvents.

The engine is upstream's source at a commit pinned in `build.zig.zon`, with one
small delta applied at build time (`engine_delta` in `build.zig`) and nothing else
changed: the two hooks that hand a matched action, and a mode change, to this
daemon. Nothing in the parser, the mappings or the tap moves, so the grammar is
upstream's exactly, and the delta stays a candidate for an upstream pull request.

The tap's callback decides and returns — an action is copied into a queue and run
in order by one worker — because macOS disables an event tap whose callback takes
too long, and a disabled tap is a keyboard that looks broken. Neither a failed
binding nor an engine that cannot start takes the daemon down: both are lines in
the log, the first of a repeating one reported once, and the bar carries on.

## The event pipe: windows, spaces and displays, natively

Everything that changes what the bar draws from yabai — a window focused, moved,
created, destroyed, minimized or retitled, an application hidden, a space switched,
created or destroyed, a display moved — reaches the daemon as an event in the
process. Nothing is provisioned into yabai and nothing spawns per event: `yabai -m
signal --list` holds no kxdesk entry, and the daemon reads the same three sources
yabai itself reads.

|source|what it reports|
|---|---|
|accessibility observers, one per application|windows created, focused, moved, resized, retitled, minimized, deminimized, destroyed|
|the workspace's notifications|an application activated, hidden or unhidden, the active space, the active display, wake|
|the window server's connection notifications|a window ordered or destroyed, a space created or destroyed|

The display *list* stays the bar's own `display_change` subscription, because the
bar is what knows the arrangement.

A title event names its window, which is the cheap path: the daemon asks yabai for
that one window's record and moves the single label, where any other event rebuilds
every space strip and front-app pair from the space and window lists. Refreshes are
held 120 ms apart, so a drag — which reports a move per frame — collapses into one
update, and an event that arrives inside the interval is drained by the receive
loop's own clock rather than dropped.

The observers need the Accessibility grant, which macOS gives only by a click in
System Settings, so the daemon asks at every start: the system's own prompt, plus
the guide panel beside the Accessibility list (`kxdesk guide`) that closes by itself
once the grant lands. Without it the pipe is off — nothing falls back to a signal —
and the bar's yabai items keep whatever they last drew; the daemon says so once in
the log and stops asking after ten minutes.

The Telegram rule runs in-process too: a window that appears with that application's
name is moved to the main display, focused, a second and a half later.

## The brew count: `kxdesk brew refresh`

The badge beside the GitHub bell is how many packages `brew outdated` lists — the
check mark when there are none. The item asks for that count on its own clock, an
hour apart, and its click starts the upgrade; a shell that has just run
`brew upgrade` knows sooner than that. So `~/.zshrc`'s `brewit` calls

```sh
kxdesk brew refresh
```

on either side of its two upgrades. The event is one block with no reply port, like
the ones the daemon posts for its own window observers: nothing waits for the work it
starts, and there is nothing to report when no daemon is listening.

Both the count and the upgrade run through the user's login shell. Homebrew reads
its trusted taps from `${XDG_CONFIG_HOME}/homebrew/trust.json`, and the daemon is
started by launchd without the `XDG_CONFIG_HOME` that shell configuration exports;
it would read `~/.homebrew/trust.json` instead and refuse every tap `brew trust`
recorded in the user's own file, which is what made an upgrade fail with "taps are
not trusted". The count is `brew outdated` under that shell, read from a marked
line so the shell's own startup cannot be counted; the upgrade is the same three
commands in a quick access terminal the daemon names (`brew`, hidden, with no file
under `quick-access-terminals`, so `term toggle` does not offer it).

A run that fails keeps its window — the shell at the end of its script holds the
output — and the item wears its failure mark. The next click shows that window; if
it has been closed in the meantime, the same output is printed in `brew-error`,
which is the terminal the daemon already keeps for a failure the store remembered.
A successful run ends the script, which closes the window, and posts the refresh
that redraws the count.

## Quick access terminals: `kxdesk term toggle`

`kxdesk term toggle <name>` shows the named kitty quick access terminal, or hides
it again — the same words from a key binding and from a shell:

```sh
kxdesk term toggle btop
```

The bar's load graphs are wired to the same thing: the pair the CPU and GPU
readings share toggles `btop` — the terminal those numbers are read in full — on
a click, and the GitHub bell toggles `ghr`, the dashboard the notifications can be
worked through. Those clicks run as background tasks, like the refreshes that
reach the network: one may start a whole kitty process, and the receive loop must
keep serving the bar while it does. The bell's click refreshes the count along with
it: what is worked through in the dashboard is what the item counts, and the item's
own schedule is three minutes long.

A terminal is one window. The shared kitty rules — `quick-access-terminal-base.kitty.conf`,
which the base hands to kitty after the normal `kitty.conf` — unbind the shortcuts
that would open a tab, a split or another OS window (kitty's defaults and the
`ctrl+f>` leader `kitty.conf` adds), hide the tab bar that carries the button
which opens one, and set the `PATH` its programs run with. That last one matters
because a terminal is started by a daemon under launchd, whose own `PATH` is
`/usr/bin:/bin:/usr/sbin:/sbin`: what runs inside a terminal looks programs up by
name, and `ghr`'s `gh` is the case that bites. Closing stays mapped: `ctrl`+`d`,
or the window's own close button, is how one is dismissed.

A terminal is two files under the kitty configuration directory:
`quick-access-terminals/<name>.conf`, the terminal's own, and
`quick-access-terminal-base.conf`, which every one of them inherits. kxdesk passes
the base first and the terminal's own file after it, so anything the base sets is
overridden there. What a terminal runs is its own file's business —
`kitty_override shell=/opt/homebrew/bin/btop` — and the word in a binding is the
file's name, and one that nothing configures is refused before anything runs: an
error on a shell, a line in the log when a binding pushed it.

Hiding and showing a terminal that is already running is a message rather than a
process. Each one is started with a socket of its own —
`listen_on unix:/tmp/kxdesk-qat-<uid>/<name>`, with remote control scoped to that
socket alone — and asked to toggle its own visibility over kitty's remote control
protocol, which is the interface kitty documents for controlling a panel from
outside, and which kitty keeps open rather than closing per command. A terminal
that is not running is the only thing that costs a process, and then it is
kitty's own `kitten quick_access_terminal` that draws the window: started hidden
and shown once it answers, so a key press never shows a window half-drawn. A
terminal that is hidden keeps running, which is what makes the second press
instant.

A panel lives on one display, and a terminal reappearing on the display it was
hidden on is not much use when the user has moved to another one. kitty's own
answer to that is `--move-to-active-monitor`, which the quick access terminal
always passes — but it is a flag of the panel process, the move happens only in
that process's own toggle path, and nothing in the remote control protocol asks
for it. So kxdesk does the move itself, and to the display the *focused window* is
on rather than the one the mouse is on: it asks yabai for the focused window's
display, asks the system for that display's name (`kitten panel --output-name
list` prints the same strings), and sets the panel's `output_name` to it. A panel
is moved only while it is hidden — the move is asked before the toggle that shows
it, and skipped when the window is already on screen, so a press that hides a
terminal never moves a window the user is looking at. When yabai cannot answer, or
no window is focused, the terminal is toggled where it is, as it was before.

## The tern mark: what the panes are doing

One item says what the panes a Tern session daemon is running are doing, in the
same small print the graphs read their numbers in: a purple `:tern:` mark with the
count of entries in Tern's needs-attention inbox above it — agents waiting on the
user, bells, failed exits — and the count of panes whose program reports work
below. A count is drawn only while it is above zero, so an idle bar carries the
mark alone, and the mark itself is dim until the daemon answers — a bar on a
machine that is not running Tern says so rather than reporting zeroes it was
never told.

`tern inspect --json` reads the session daemon's own socket — no network, no
window attached — and the item's own two-second clock is what asks for it, because
nothing but Tern knows that an agent finished. The inbox's count is the window's
own state (`tern ctl state`), reached the way a pane reaches it, through the
daemon socket; with no window open there is no inbox to read and the count stays
zero. A Tern with no daemon exits instead of starting one of its own, which is
what makes polling it from the daemon safe; any other failure is a line in the
log, once.

## The audio spectrum

`audio.spectrum` draws the audio the machine is playing: 59 bands of a
1024-sample window, low frequencies on the left, drawn twenty times a second. It
is not a graph of one value over time like the load and network pairs — every
column is a band and every frame replaces all of them, so the item reads as a
spectrum rather than as a history, and it is placed to the right of the notch,
with the pomodoro's countdown to its left: the two are the pair that brackets it.
A band is
its loudest FFT bin in decibels, mapped onto the bar over 70 dB, and it falls
rather than disappears when the note does: at twenty frames a second a bar that
went out at once would read as a flicker. `src/spectrum.zig` is that arithmetic
and nothing else — the window, the FFT, the geometric band edges and the decay —
and `src/items_audio.zig` owns the item's name, its frame clock and the batch it
sends. Twenty frames a second costs the daemon well under a percent of a core,
and the bar as much again.

The audio comes from a CoreAudio process tap, `kx_audio_*` in `src/platform.m`: a
private stereo tap on every process's output, carried by a private aggregate
device of its own, with an IOProc that mixes the stream down to mono and appends
it to a ring the daemon takes the newest window out of. The audio keeps playing
while it is read, and the tap follows the machine's output device, so the
spectrum's frequency axis follows the sample rate with it rather than staying at
whatever it was when the daemon started.

**The tap needs the "System Audio Recording" permission.** macOS asks for it the
first time a process starts one, and it names the application that started the
process: for a daemon under launchd that is the daemon's own binary, so the first
start after an upgrade or a `brew services restart` puts the prompt up once and
waits for it. The daemon asks from a task of its own rather than from the receive
loop, so the bar keeps being served while the prompt is up, and until it is
answered the item is a flat line and the log says so once. It keeps asking every
thirty seconds, because the answer can be changed in System Settings > Privacy &
Security > System Audio Recording while the daemon runs, and nothing tells the
daemon that it was.

## Installing on a new machine

```sh
brew install kvndrsslr/formulae/kxdesk
brew services start kxdesk
chezmoi apply                    # ~/.config/kxdesk/skhdrc among the rest
sudo kxdesk grabber install      # home-row mods: driver, daemon, then the tile to drag
```

Then grant Accessibility to `kxdesk` once, when macOS asks (System Settings >
Privacy & Security > Accessibility, named *Device Control and Data Access* on macOS
27). No root, no driver extension, no kanata. The
install is a `.app` bundle (`kxdesk.app`) precisely so that grant survives an
upgrade: macOS keys it to the bundle identifier, where a bare binary's grant is
keyed to a hash that every build changes. `bin/kxdesk` is still installed as a
plain executable for the command line, which needs no identity at all.

## Installing: currently from HEAD, temporarily

**The installed copy is a HEAD build on purpose, while this is still being
worked on.** It is built from `main` rather than from a tagged release, so a
change reaches the machine with `git push` and nothing else — no tap commit, no
version bump, no tag.

```sh
./deploy.sh              # from the checkout: push, then the two steps below
```

Run by hand, that is the push (the formula builds from `main` on GitHub, so the
commit has to be there first) followed by

```sh
brew upgrade --fetch-HEAD kxdesk
brew services restart kxdesk
```

Note that a plain `brew upgrade` will *not* move it: a HEAD install is versioned
`HEAD-<sha>`, so it needs `--fetch-HEAD` (or `brew reinstall --HEAD kxdesk`).

### Switch back to releases when the iterating stops

This is the part to not forget. The tap formula
(`kvndrsslr/formulae/kxdesk.rb`) is pinned to **v0.1.23** and has not been
updated since HEAD installs took over, so it is stale:

1. Bump `.version` in `build.zig.zon`, commit, and tag the release.
2. Point the tap's `tag:` and `revision:` at that tag and push the tap.
3. Replace the HEAD install with the released one:

   ```sh
   brew unlink kxdesk
   brew install kvndrsslr/formulae/kxdesk
   brew services restart kxdesk
   ```

4. Delete this section, or reduce it to the ordinary install instructions.

## Building from a checkout

```sh
zig build                  # fast (optimized), into zig-out/bin/kxdesk
./zig-out/bin/kxdesk daemon
```

The daemon registers two bootstrap names on one receive port: `org.kdressler.kxdesk`
for SketchyBar item events (the value items carry as `mach_helper`) and
`org.kdressler.kxdesk.control` for `kxdesk <command>` clients. Only one daemon
can hold them, so stop the agent (`brew services stop kxdesk`) before running a
checkout's `daemon`.

Three provider tokens are read from the state database rather than the
environment, since the daemon runs under launchd:

```sh
kxdesk state set neuralwatt.token 'sk-…'
kxdesk state set openrouter.token 'sk-or-v1-…'
kxdesk state set opencode-go.token '…'
```

Each gets an item on the bar: `:neuralwatt:` and `:openrouter:` with what is left
of the balance, and `:opencode-go:` with the share of the tightest of the Go
plan's three windows — five rolling hours, the week, the month — since that is
the one that would stop the next request. The Go mark is ringed: the ring carries
the month's own share, green while half the month is left, yellow to four fifths
and orange past that, and the moment any window is at its limit the ring and the
mark go red and the number goes away. Hovering shows the windows the provider
reports, down to when each resets; clicking opens its usage page. OpenRouter
reports no windows to a normal key, so its hover is empty and it is subscribed to
clicks alone.

## Server mode: this Mac as a remote coding server

`kxdesk server-mode [enter|exit|toggle|status|refresh]` — `status` when no verb is
given. It is the port of the standalone `kxb-server-mode` script, which it
replaces along with that script's own state directory.

A machine that must not serve at all — a compliance one — turns the mode off
wholesale with one key, so that nothing here can enter it:

```sh
kxdesk state set server-mode.disabled 1   # every verb refuses from now on
kxdesk apply                              # and the bar drops the item
kxdesk state unset server-mode.disabled   # the way back
```

With the key set, every `server-mode` verb answers
`kxdesk: server mode is disabled on this machine`, nothing materializes a key or
touches ssh, git or `launchctl`, and the next `kxdesk apply` — or a restarted
daemon — leaves the `server` item off the bar. Only an explicit false leaves the
mode available: `0`, `false`, `no`, `off`, whitespace and an empty value, a
`--null` write included. A value that means nothing, a typo included, therefore
turns the mode off, which is the direction the key exists for. A store that cannot
be read at all leaves the mode as it was, available: the key is the only thing
that could have said otherwise.

The bar says which state the mode is in: a `server` item beside the date, grey
when the mode is off, green when it is on, and an hourglass while a change is in
flight. Clicking it toggles the mode — `server-mode toggle` — and the click's
output is kept in `…/kxdesk/server-mode/last-click.log`, since a click has no
terminal for it.

Leaving the mode from the bar works; entering it from the bar cannot. The click
is a child of the bar, and 1Password's app integration is not granted to one: `op`
run there answers `No accounts configured for use with 1Password CLI`, because
the group container it asks the app through answers `Operation not permitted`.
Neither is it granted to the daemon's children, nor to a launchd job's binary —
only a shell's own `op` is answered, which is why the command is run from a shell
and why **`enter` belongs to one**. The item is still the way to see the state,
and a click still takes the mode off.

Unlike every other command, `server-mode` runs in the client rather than in the
daemon: it is the only one that drives `op`, and 1Password's app integration is
granted to contexts the daemon's own children are not. `op` started by the daemon
exits non-zero rather than asking for an approval that nobody there can give,
which is why the bar's click goes through launchd and why the command is meant to
be run from a shell.

- **enter** materializes every SSH key of the personal 1Password account
  (`my.1password.com`; the business account is never read) under
  `~/Library/Application Support/kxdesk/server-mode/keys`, loads them into one
  persistent ssh-agent on `…/server-mode/agent.sock`, points `~/.ssh/config`'s
  `IdentityAgent` at that socket, switches git's commit and tag signing to the
  on-disk key through `ssh-keygen`, and loads the AC-only `local.caffeinate.ac`
  keep-awake agent so the machine does not sleep. One 1Password approval covers
  the run; ssh and git signing pay none afterwards, on any host.
- **exit** puts every one of those back from the snapshot enter took — the ssh
  config, the three git settings, the keep-awake service — stops the agent and
  wipes the keys.
- **toggle** enters the mode if it is off and leaves it if it is on: what the
  bar item's click asks for.
- **status** says whether the mode is on, how many identities the agent holds
  and which key git signs with.
- **refresh** is exit then enter, for a key or a remote that was added in
  1Password since.

Everything the mode changes is recorded under
`~/Library/Application Support/kxdesk/server-mode`: the ssh config and the git
settings it has to restore, the materialized keys, and the `active` cookie that
says the mode is on. The ssh config and the git snapshot are written before the
first change and read back on `exit`, so leaving server mode returns the machine
to exactly what it was, and an enter that fails halfway can still be undone.
