# Repository Guidelines

## Project Overview

Swiss-army knife for desktop productivity on macOS, in Zig. One daemon serves SketchyBar item events and `kxdesk <command>` clients over one mach port, and owns shared state in one SQLite DB.

## Architecture & Data Flow

Single binary, single long-lived process (`src/main.zig:Daemon`).

- Transport: `src/platform.m` (`kx_server_serve`) blocks main thread → `onBlock` in `src/main.zig`. Two bootstrap names, one receive port: `org.kdressler.kxdesk` (bar item events via `mach_helper=`) and `org.kdressler.kxdesk.control` (CLI clients).
- Framing: bar events are NUL-separated `key\0value\0…`; control requests are `CMD\0<verb>\0<args>…` (`src/control.zig`). Replies `OK\0<payload>` / `ERR\0<message>` to request reply port; bar sends are one-way.
- Routing: `isRequest` → control path, else `src/dispatch.zig:Dispatcher` looks up `NAME`/`SENDER` (names mirror `mach_helper` items declared in `src/bar.zig`). No forks on this path; clicks are events.
- Commands: run as worker tasks on `commands.Context` (own arena freed on return, own `sb.Client`, shared `yabai.Client`, `pomodoro.Timer`, `store.Store`). One `background.Slot` per command in `Daemon.slots` — never run twice, never block loop.
- One vocabulary for window management: every window/space/display verb and yabai's provisioning is a subcommand of `kxdesk wm` (`src/yabai_ops.zig:wm_verbs`), and a kanata binding pushes that same argv line minus the binary name — `src/kanata.zig:dispatch` looks it up in the registry and runs it through `cli.validate`, the check a client's request gets.
- Slow refreshes (`brew`, `gh`, usage APIs): `background.Slot.request` → `std.Io.async` pool; task awaits prior `Future` off-loop, applies own bar updates on finish (`src/background.zig:Slot`, `src/dispatch.zig`, `src/items_github.zig`, `src/items_usage.zig`).
- Bar writes: batched `--set` via `sb.Client`; `bar.zig` emits whole config in one batch (single redraw). Commands calling bar use `Context.ensureBar` with reconnect+retry (`src/context.zig:ensureBar`).
- Platform seam: all Mach/ObjC/libc contact through `src/platform.zig` (`extern "c"`) → `src/platform.m`/`src/platform.h`. Everything else is platform-free logic.
- State: `src/store.zig:Store` wraps one SQLite file; shared under `std.Io.Mutex`. Best-effort: open failure → `error.Unavailable`, daemon still runs.
- Exception: `server-mode` runs in the client, not daemon — drives `op`/1Password, whose app integration macOS grants to a shell and refuses to a child of the daemon, of the bar, or of a launchd job's binary (`src/server_mode.zig:1-10`, `src/main.zig:runLocally`). Its bar item (`server`, `src/bar.zig`) carries the only `click_script` on the bar (`server_mode.clickScript`): a toggle whose `exit` needs no `op` and works, whose `enter` does not — so entering stays a shell command. The client renders that item and serializes changes on a lock in its state dir; the daemon only restores it on `apply` (`commands.restoreState`).

## Key Directories

- `src/`: all logic (~30 `.zig` + `platform.m`/`.h`). No `src/` subdirs; `items_*.zig` per bar-item family.
- `vendor/`: `sketchybar.h` (upstream mach wire format, do not hand-edit), `sqlite.h` (1-line translate-C shim).
- `zig-out/`, `.zig-cache/`: build output (gitignored). Nothing else generated.
- No `tests/`, `scripts/`, `docs/`, `.github/`.

## Development Commands

```sh
zig build                  # ReleaseFast default → zig-out/bin/kxdesk
zig build -Doptimize=Debug # debugging
zig build test             # the unit tests in src/tests.zig
./zig-out/bin/kxdesk daemon
brew services stop kxdesk  # REQUIRED before checkout daemon (bootstrap names exclusive)
kxdesk --help              # all commands (works with no daemon)
kxdesk help <command>      # one command in full
kxdesk <command> --help    # same, without running
KXDESK_STATE=/tmp/x.db ./zig-out/bin/kxdesk …  # sandbox state DB for probes
zig fmt                    # canonical formatter (no config file)
```

Install is a HEAD build (`brew upgrade --fetch-HEAD kxdesk && brew services restart kxdesk`); tap formula pinned stale at v0.1.23 — see `README.md` "Switch back to releases".

## Code Conventions & Common Patterns

- Every file opens with a `//!` module doc: one purpose sentence plus the facts that hold module-wide. A `///` states the caller-facing contract; an inline `//` carries only what the code cannot (a measured constant, a fork quirk, a wire format, an ordering requirement). No narration, no history, no restating code or an assert, no section banners.
- SketchyBar assembly goes through `src/config.zig` (`config.declare`/`add`/`subscribe`/`move`/`remove`, and `config.node` for comptime property literals), `src/props.zig:Props.write` for values only known at runtime, and `src/style.zig` for anything an item draws with. Never hand-spell `key=value` property strings or `--add`/`--subscribe` boilerplate. Inside a node a nested plain struct is a node and a leaf named `value` collapses to its parent's key — so a two-level key whose last segment is `value` is written as a field literally named `"ring.value"`.
- Single source of truth, never restated: commands in `src/commands.zig` (help/completions/validation derive via `src/cli.zig`); version in `build.zig.zon` (injected as `build_options` in `build.zig:26-28`).
- No-alloc hot paths: `src/props.zig:Props` (4 KiB scratch + 64 items, `std.debug.assert` on overflow), fixed `[max_path_bytes]` buffers, `bufPrint` into caller buffers. Do not introduce allocators there.
- Per-command arena: everything a command allocates comes from `Context.arena`; freed wholesale on return — no individual frees.
- Concurrency: receive-loop handlers run one at a time and share `Daemon.bar`; background/command tasks build their own `sb.Client`. Shared mutable item state (e.g. github URL registry) under mutex.
- Error handling: named errors (`error.NotInstalled`, `error.OnePasswordUnavailable`, `error.Unavailable`); failures log through `src/log.zig` (`log.warn`; `log.Once` reports a repeating failure once) and never take the loop down.
- Bounded static sizes: `control.max_arguments = 8`, `Props` 64 items, `path` buffers. Overflow = bug, assert it.
- External tools resolved to absolute paths via `src/exec.zig:path` — launchd `PATH` lacks Homebrew; never shell out by bare name, never use a shell. `exec.openApp`/`exec.spawn` launch detached applications (`kxdesk app open`), never waited for.
- Store rules (`src/store.zig`): never take daemon down; corrupt DB renamed to `state.db.corrupt-<timestamp>` and replaced, never repaired in place; `schema_version` bump + `migrate` step together.
- Bar reload leaks: `Script.apply` clears `script=`/`click_script=` on every item it configures, so only `drawing` is restated by an item's own props; retiring an item = removing it + listing it in `retired_items` (`src/bar.zig:21`).

## Important Files

- Entry: `src/main.zig` (`Daemon`, receive loop, client dispatch).
- CLI surface: `src/commands.zig` (registry + every `run`), `src/cli.zig` (help/completions/validation).
- Transport: `src/control.zig` (CMD/OK/ERR), `src/platform.zig`/`.m`/`.h`, `src/sb.zig` (bar client).
- Config/render: `src/config.zig` (the SketchyBar command layer), `src/style.zig` (shared fonts, chips, ring/graph look and geometry), `src/props.zig` (runtime property bridge), `src/log.zig`, `src/bar.zig`, `src/theme.zig`, `src/items_yabai.zig`, `src/items_system.zig`, `src/items_usage.zig`, `src/items_github.zig`, `src/items_brew.zig`.
- Subsystems: `src/store.zig` (SQLite), `src/yabai.zig` + `src/yabai_ops.zig` (yabai queries, and the `wm` verb table), `src/pomodoro.zig`, `src/zen.zig`, `src/mode_indicator.zig`, `src/server_mode.zig`, `src/background.zig`, `src/exec.zig`, `src/app_icons.zig`.
- Build/version/docs: `build.zig`, `build.zig.zon` (version `0.1.24`), `README.md` (only doc), `.gitignore` (only `zig-out/`, `.zig-cache/`).

## Runtime/Tooling Preferences

- Zig `>=0.16.0` (`build.zig.zon:minimum_zig_version`) — only toolchain. No Node/Bun/Python, no package manager, no Makefile/just/Docker/Nix/CI.
- macOS-only (arm64): `link_libc`, system `sqlite3` (translate-C of `vendor/sqlite.h`), frameworks AppKit/CoreFoundation/CoreText/Foundation/IOKit; `platform.m` compiled `-fobjc-arc -Wall -Wextra -Wno-unused-parameter`.
- Default `optimize=ReleaseFast` (bar event path); override `-Doptimize=Debug` for debugging.
- Secrets/tokens live in state DB (`kxdesk state set neuralwatt.token …`), not env — daemon runs under launchd.

## Testing & QA

Tests live in `src/tests.zig` and run with `zig build test`: the `test` step in `build.zig` compiles that file alone, so a module's tests are reached only once it is imported there. There is still no CI, no coverage and no fixtures.

- Verify by building + exercising the live binary: `zig build`, then `kxdesk --help`, `kxdesk <command> --help`, `kxdesk state …`, or a checkout `daemon` (after stopping the service).
- `KXDESK_STATE` (`src/store.zig:51`) is the intended sandbox seam for probes/tests, and the suite sets it to keep off the real store.
- New tests only for genuinely uncertain edges, per repo note that platform-free modules are designed testable (`src/tests.zig:1-5`); Fish completions intentionally unsupported (ships untested otherwise).
