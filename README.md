# kxdesk

A personal desktop daemon for macOS. It serves SketchyBar's item events and a
command channel over one mach port, so the bar's items are configured in Zig
instead of shell, clicks arrive as events instead of forked processes, and the
commands that `~/.skhdrc`, `~/.yabairc`, yabai signals and the bar's config
script run are answered by one long-lived process.

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
`state get` offers the keys that are actually in the store, and `switch_workspace`
offers the labels yabai is actually carrying (see `kxdesk space_labels`). Those
come from the running daemon and are simply absent when there is not one;
pressing TAB never starts it.

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

Two provider tokens are read from the state database rather than the
environment, since the daemon runs under launchd:

```sh
kxdesk state set neuralwatt.token 'sk-…'
kxdesk state set openrouter.token 'sk-or-v1-…'
```

## Server mode: this Mac as a remote coding server

`kxdesk server-mode [enter|exit|status|refresh]` — `status` when no verb is
given. It is the port of the standalone `kxb-server-mode` script, which it
replaces along with that script's own state directory.

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
