//! Thin Zig bindings for `src/platform.m`; every Mach, Objective-C and libc
//! contact happens here. `src/platform.h` owns each function's contract.

/// A received block handed to the server, valid only for the duration of the call;
/// `reply_port` is 0 for SketchyBar's one-way sends, and a handler that answers
/// from a worker task must take a reference to it first.
pub const Handler = *const fn (block: [*:0]const u8, reply_port: u32) callconv(.c) void;

/// Work the loop has to do on a clock; called before the loop blocks, and answers
/// how long it may block for.
pub const Timer = *const fn () callconv(.c) u32;

pub extern "c" fn kx_bootstrap_lookup(name: [*:0]const u8) u32;
pub extern "c" fn kx_port_release(port: u32) void;
pub extern "c" fn kx_server_register(name: [*:0]const u8) u32;
pub extern "c" fn kx_server_serve(port: u32, handler: Handler, timer: ?Timer) void;
pub extern "c" fn kx_send(
    port: u32,
    argv: [*]const u8,
    len: usize,
    out: ?[*]u8,
    cap: usize,
    timeout_ms: u32,
) i32;
pub extern "c" fn kx_post(port: u32, argv: [*]const u8, len: usize) i32;
pub extern "c" fn kx_port_copy(port: u32) u32;
pub extern "c" fn kx_server_publish(port: u32, name: [*:0]const u8) bool;
pub extern "c" fn kx_uid() u32;

/// This process's executable path, for spawning the same binary as a helper.
pub extern "c" fn kx_self_path(out: [*]u8, cap: usize) bool;

pub extern "c" fn kx_exec_capture(
    argv: [*]const ?[*:0]const u8,
    out: [*]u8,
    cap: usize,
) i64;

pub extern "c" fn kx_exec_status(argv: [*]const ?[*:0]const u8) i32;

/// One message to a unix stream socket, and its reply; see `src/platform.h` for
/// the return convention.
pub extern "c" fn kx_socket_message(
    path: [*:0]const u8,
    request: [*]const u8,
    request_size: usize,
    out: [*]u8,
    cap: usize,
) i64;

/// One message to a unix stream socket, read until `terminator` has arrived
/// rather than to end of file: the reply's length, or -1 when nothing connected,
/// nothing was sent, or nothing arrived within `timeout_ms`. Exactly `cap` bytes
/// means the reply did not fit and was cut.
pub extern "c" fn kx_unix_reply(
    path: [*:0]const u8,
    request: [*]const u8,
    request_size: usize,
    terminator: [*]const u8,
    terminator_size: usize,
    out: [*]u8,
    cap: usize,
    timeout_ms: u32,
) i64;

pub extern "c" fn kx_spawn_detached(argv: [*]const ?[*:0]const u8) i32;

pub extern "c" fn kx_reap(pid: i32) bool;

pub extern "c" fn kx_which(name: [*:0]const u8, out: [*]u8, cap: usize) bool;

pub extern "c" fn kx_env(name: [*:0]const u8, out: [*]u8, cap: usize) bool;
pub extern "c" fn kx_app_font_path(out: [*]u8, cap: usize) bool;
pub extern "c" fn kx_battery(percent: *i32, charging: *bool) bool;
pub extern "c" fn kx_clock(
    icon: [*]u8,
    icon_cap: usize,
    label: [*]u8,
    label_cap: usize,
) void;

pub extern "c" fn kx_cpu_load() f64;
pub extern "c" fn kx_gpu_load() f64;
/// The two dies' temperatures in Celsius. A die this machine never answered is
/// written as NaN, so one reading stays usable without the other; false when
/// neither answered.
pub extern "c" fn kx_temperatures(cpu_celsius: *f64, gpu_celsius: *f64) bool;

/// Where the audio tap got to, in the order `src/platform.h` spells it. The tap
/// is the machine's own output audio, mixed down to one stream; `kx_audio_start`
/// is the call that blocks on the system's permission prompt, so it is never
/// made from the receive loop.
pub const AudioStatus = enum(u8) {
    /// Never asked for, or torn down after a failure.
    off = 0,
    /// Asked for; the system has not answered yet.
    starting = 1,
    /// Delivering the machine's output audio.
    running = 2,
    /// The last attempt did not produce a tap.
    failed = 3,
};

pub extern "c" fn kx_audio_start() bool;
pub extern "c" fn kx_audio_status() u8;
pub extern "c" fn kx_audio_rate() f64;
pub extern "c" fn kx_audio_window(out: [*]f32, count: usize) bool;
pub extern "c" fn kx_net_bytes(received: *u64, sent: *u64) bool;

/// The link the machine is on, in the order `src/platform.h` spells it: no primary
/// interface at all, Wi-Fi, or anything else.
pub const Link = enum(u8) { disconnected = 0, wifi = 1, wired = 2 };

pub extern "c" fn kx_net_link() u8;
pub extern "c" fn kx_dark_mode() bool;
pub extern "c" fn kx_open_url(url: [*:0]const u8) bool;
pub extern "c" fn kx_browser_open() bool;

pub extern "c" fn kx_clipboard_set(text: [*:0]const u8) bool;

/// Whether this process holds the Accessibility grant an event tap needs.
pub extern "c" fn kx_ax_trusted() bool;

/// One event the native window observers report; see `src/platform.h` for what
/// each `kind` means and which thread it arrives on.
pub const WmHandler = *const fn (
    kind: [*:0]const u8,
    window_id: u32,
    app_name: [*:0]const u8,
) callconv(.c) void;

/// Start the native window, space and display observers; false when the pipe is
/// already armed for another handler.
pub extern "c" fn kx_wm_events_start(handler: WmHandler) bool;

/// Ask for the Accessibility grant the observers need, showing the system's
/// prompt when it is missing; answers whether it is held now.
pub extern "c" fn kx_ax_request() bool;

/// Input Monitoring, the second grant a tap needs before key events reach it.
pub const InputMonitoring = enum(u8) { granted, denied, unknown };

/// What macOS answers for this process's Input Monitoring grant; `unknown` means
/// the user has never been asked.
pub fn inputMonitoring() InputMonitoring {
    return switch (kx_input_monitoring()) {
        0 => .granted,
        1 => .denied,
        else => .unknown,
    };
}

extern "c" fn kx_input_monitoring() u8;

/// Ask for that grant. The system shows its own dialog and this blocks until it
/// is answered, so it is called from a command and never on a startup path.
pub extern "c" fn kx_request_input_monitoring() bool;

/// Spin this thread's main run loop forever: the loop the observers deliver on.
pub extern "c" fn kx_run_loop_run() void;

/// A compact signature of the desk's spaces - see `src/platform.h`; comparing two
/// tells whether a space appeared, disappeared or took the focus.
pub extern "c" fn kx_space_signature(out: [*]u8, cap: usize) bool;

/// The name the system gives a display, which is the name kitty knows it by;
/// false when no display of that id is attached or the name does not fit `out`.
pub extern "c" fn kx_display_name(display_id: u32, out: [*]u8, cap: usize) bool;

/// The name of the attached display at `index` of the system's list, answering
/// false past the end: every name a panel's move could take.
pub extern "c" fn kx_display_name_at(index: usize, out: [*]u8, cap: usize) bool;

/// Whether that process has a window on screen right now: the state a quick
/// access terminal's panel is shown or hidden in.
pub extern "c" fn kx_has_onscreen_window(pid: i32) bool;

/// The display the panel window of `pid` is on, or -1 when it has none: what says
/// a move happened - see `src/platform.h`.
pub extern "c" fn kx_panel_display(pid: i32) i32;

/// Stop the blackout helper listening on `path`, if one is up.
pub extern "c" fn kx_blackout_stop(path: [*:0]const u8) bool;

/// Run the blackout overlay over every screen but `display_id`; see
/// `src/platform.h` for the two ways it ends.
pub extern "c" fn kx_blackout_run(display_id: u32, path: [*:0]const u8) bool;

/// Whether the grant the guide was shown for has landed; polled from the panel's
/// own thread, never the caller's.
pub const GuideDone = *const fn () callconv(.c) bool;

/// Show the guide beside the Input Monitoring pane; see `src/platform.h` for what
/// each argument means. Blocks until the panel closes.
pub extern "c" fn kx_guide_run(
    bundle: ?[*:0]const u8,
    instruction: [*:0]const u8,
    pane: [*:0]const u8,
    script: ?[*:0]const u8,
    done: ?GuideDone,
) bool;
