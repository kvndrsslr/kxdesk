//! Time budgets for inter-process waits, in one place: SketchyBar answering a
//! query, the daemon answering a control request, a replaced daemon reappearing,
//! and a freshly started daemon or bar publishing its bootstrap name. The two
//! start waits live here so they stay the same wait instead of drifting apart;
//! buffer sizes do not, since each sizes the buffer it sits next to -
//! `control.max_reply`, `sb.response_bytes`, `yabai.max_response`.

/// How long to wait for SketchyBar to answer a query. It applies commands on
/// its own thread and answers immediately, so this only elapses when it is
/// wedged; the daemon's event path must not sit on a query for longer than
/// that.
pub const query_timeout_ms: u32 = 1000;

/// How long a client waits for the daemon to answer. A provisioning command
/// such as `refresh_signals` runs a dozen yabai commands, so this is
/// generous; it only elapses when the daemon is wedged.
pub const reply_timeout_ms: u32 = 30_000;

/// How long a client that reached a daemon which then went away waits before
/// asking again.
pub const retry_delay_ms: u32 = 250;

/// How long to wait for a freshly started process to publish its bootstrap
/// name, and how often to look. Covers a restart, but short enough that a
/// command on a machine with nothing listening still fails quickly.
pub const start_timeout_ms: u32 = 2_000;
pub const start_poll_ms: u32 = 50;
