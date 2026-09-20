//! Thin Zig bindings for `src/platform.m`.
//!
//! All Mach, Objective-C and libc contact happens through this module; the rest
//! of the daemon is platform-free logic that can be reasoned about (and tested)
//! on its own.

/// A received block handed to the server: either a NUL-separated
/// `key\0value\0...\0` event, a `CMD\0verb\0...` request, or SketchyBar's bare
/// `k` marker. Only valid for the duration of the call. `reply_port` is 0 for
/// SketchyBar's one-way sends and must be `kx_port_copy`ed to outlive the call.
pub const Handler = *const fn (block: [*:0]const u8, reply_port: u32) callconv(.c) void;

pub extern "c" fn kx_bootstrap_lookup(name: [*:0]const u8) u32;
pub extern "c" fn kx_port_release(port: u32) void;
pub extern "c" fn kx_server_register(name: [*:0]const u8) u32;
pub const Timer = *const fn () callconv(.c) u32;
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

pub extern "c" fn kx_exec_capture(
    argv: [*]const ?[*:0]const u8,
    out: [*]u8,
    cap: usize,
) i64;

pub extern "c" fn kx_exec_status(argv: [*]const ?[*:0]const u8) i32;

/// One message to a unix stream socket, and its reply. Returns the reply length
/// (0 for a peer that answers nothing), exactly `cap` when the reply did not
/// fit, or -1 when the socket could not be used at all. `out` is always
/// NUL-terminated.
pub extern "c" fn kx_socket_message(
    path: [*:0]const u8,
    request: [*]const u8,
    request_size: usize,
    out: [*]u8,
    cap: usize,
) i64;

pub extern "c" fn kx_spawn_detached(argv: [*]const ?[*:0]const u8) i32;

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
pub extern "c" fn kx_net_bytes(received: *u64, sent: *u64) bool;

/// The internet link the machine is on, in the order `src/platform.h` spells it:
/// no primary interface at all, Wi-Fi, or anything else.
pub const Link = enum(u8) { disconnected = 0, wifi = 1, wired = 2 };

pub extern "c" fn kx_net_link() u8;
pub extern "c" fn kx_dark_mode() bool;
pub extern "c" fn kx_open_url(url: [*:0]const u8) bool;

/// Connect to a TCP peer and keep the descriptor, for a channel that stays open
/// - the opposite of `kx_socket_message`, which is one message and gone.
/// Returns -1 while the peer is not listening, which is the ordinary answer and
/// the caller's cue to try again.
pub extern "c" fn kx_tcp_connect(host: [*:0]const u8, port: u16) i32;

/// Read up to `cap` bytes: the number read, 0 when the peer closed the
/// connection, or -1 on a read error.
pub extern "c" fn kx_tcp_read(fd: i32, out: [*]u8, cap: usize) i64;

/// Send `buffer` whole: true when every byte went out, false when the peer
/// went away first, which for a message to kanata is a tap that did not happen.
pub extern "c" fn kx_tcp_write(fd: i32, buffer: [*]const u8, len: usize) bool;

pub extern "c" fn kx_tcp_close(fd: i32) void;

/// Replace the general pasteboard's contents with `text`.
pub extern "c" fn kx_clipboard_set(text: [*:0]const u8) bool;
