# kxdesk

A personal desktop daemon for macOS. It serves SketchyBar's item events and a
command channel over one mach port, so the bar's items are configured in Zig
instead of shell, clicks arrive as events instead of forked processes, and the
commands that kanata's key bindings, `~/.yabairc`, yabai signals and the bar's
config script name are answered by one long-lived process.

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

## The key bindings: kanata's channel

The bindings themselves live in kanata, in
`~/Library/Application Support/kanata/kanata.kbd`. What they *run* does not: each
binding pushes a message, and the message is a `kxdesk` argv line with the binary
name left off — `wm window-swap west`, `wm cycle-displays --reverse`,
`app open kitty`, `term toggle btop` — which this daemon receives, checks against
the same command description a request from a shell is checked against, and runs.

That is the whole vocabulary: every window, space and display verb is a
subcommand of `kxdesk wm`, together with yabai's provisioning (`wm apply-settings`,
`wm refresh-rules`, `wm refresh-signals`), so a binding and the command a script
writes are the same words — `~/.yabairc` calls `kxdesk wm apply-settings`.

The split between the bindings and the commands they run is both forced and
deliberate. kanata's own `cmd` action is compiled out of the Homebrew bottle, and
on macOS kanata has to run as root to seize the keyboard through the Karabiner
driver — so a config file, which is the user's to write, would be able to run
anything as root. Upstream ships `cmd` in a separate binary for exactly that
reason. A pushed name cannot execute anything: the vocabulary is the command
registry and nothing else, every argument is checked before anything runs, and the
command is carried out here, as the user, in the user's session.

It is cheaper too. kanata's documentation puts `cmd` at around 100 ms per
keypress against sub-millisecond for a pushed message: one forks a process, the
other is a line on a socket.

The channel is kanata's TCP server on `127.0.0.1:4038`. The port is not a knob to
guess at — the launchd job passes it to kanata with `-p` and this daemon reads the
same default:

```sh
kxdesk kanata status                              # is the channel up, and what has it carried
kxdesk kanata inject "wm window-swap west"        # run a command as if a key had pushed it
```

`inject` takes an argv line (one quoted argument containing its spaces) or a raw
JSON line, which is what makes a binding testable without pressing its keys — and
the channel testable with kanata not running at all, since the lookup, the check
and the run are the same code the socket path runs.

Three kinds of message are acted on, out of the several kanata sends:

- **`MessagePush`** — a binding. kanata sends the name inside a one-element JSON
  array (`{"message":["wm window-swap west"]}`), because it converts the
  action's arguments with `simple_sexpr_to_json_array`; a bare string is read
  too, since the field is a `serde_json::Value` on kanata's side. The name is
  split on spaces, looked up in the registry in `src/commands.zig` and validated
  by `src/cli.zig`, exactly as a client's request is, and refused with the reason
  when it does not fit — so a typo in the config is a line in the log rather than
  a key that does nothing.
- **`LayerChange`** — kanata switched layer, which is what colours the bar's
  space icons. `op`, `wmode` and `smode` are the indices the skhd config used to
  pass to `set_mode_indicator` on entering each mode, and `default` clears them.
  The layer is the state and the event says it changed, so no binding has to
  remember to set the indicator.
- **`ConfigFileReload`** — the config was reloaded, which returns to the default
  layer, so the highlight goes with it.

The reader is a thread of its own, because the serve loop only ever waits on its
mach port and because kanata restarts: the connection is made, lost and made
again for as long as this daemon lives. Neither a kanata that is down nor a
binding that fails is a reason for the daemon to stop serving the bar — both are
lines in the log, the first failure of a run once and not once per retry.

To move the two ends apart, `kxdesk state set kanata.port <port>` (and
`kanata.host`) changes this side without a rebuild; the other side is the `-p`
argument in the launcher the `kxkanata` formula installs, which is what
`brew services` starts (`/opt/homebrew/bin/kxkanata`, `brew services info
kxkanata`).

## Quick access terminals: `kxdesk term toggle`

`kxdesk term toggle <name>` shows the named kitty quick access terminal, or hides
it again — the same words from a key binding and from a shell:

```sh
kxdesk term toggle btop
```

The bar's load graphs are wired to the same thing: the pair the CPU and GPU
readings share toggles `btop` — the terminal those numbers are read in full — on
a click, so the two instruments are one click apart. That click runs as a
background task, like the refreshes that reach the network: it may start a whole
kitty process, and the receive loop must keep serving the bar while it does.

A terminal is two files under the kitty configuration directory:
`quick-access-terminals/<name>.conf`, the terminal's own, and
`quick-access-terminal-base.conf`, which every one of them inherits. kxdesk passes
the base first and the terminal's own file after it, so anything the base sets is
overridden there. What a terminal runs is its own file's business —
`kitty_override shell=/opt/homebrew/bin/btop` — and the program is spelled in
full, because the window is started by a daemon under launchd, whose `PATH` has no
Homebrew in it. The word in a binding is the file's name, and one that nothing
configures is refused before anything runs: an error on a shell, a line in the
log when a binding pushed it.

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
instant — and the one thing that cannot be asked for over remote control is what
kitty's own `--move-to-active-monitor` does, so a terminal reappears where it was
hidden rather than following the mouse to another monitor.

## Installing: currently from HEAD, temporarily

**The installed copy is a HEAD build on purpose, while this is still being
worked on.** It is built from `main` rather than from a tagged release, so a
change reaches the machine with `git push` and nothing else — no tap commit, no
version bump, no tag.

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
zig build                  # ReleaseFast, into zig-out/bin/kxdesk
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
