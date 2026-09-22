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

/// The link the machine is on, in the order `src/platform.h` spells it: no primary
/// interface at all, Wi-Fi, or anything else.
pub const Link = enum(u8) { disconnected = 0, wifi = 1, wired = 2 };

pub extern "c" fn kx_net_link() u8;
pub extern "c" fn kx_dark_mode() bool;
pub extern "c" fn kx_open_url(url: [*:0]const u8) bool;

/// Connect to a TCP peer and keep the descriptor, for a channel that stays open;
/// -1 while the peer is not listening, which is the caller's cue to try again.
pub extern "c" fn kx_tcp_connect(host: [*:0]const u8, port: u16) i32;

/// Read up to `cap` bytes: the number read, 0 when the peer closed the connection,
/// or -1 on a read error.
pub extern "c" fn kx_tcp_read(fd: i32, out: [*]u8, cap: usize) i64;

/// Send `buffer` whole; false means the peer went away first, which for a message
/// to kanata is a tap that did not happen.
pub extern "c" fn kx_tcp_write(fd: i32, buffer: [*]const u8, len: usize) bool;

pub extern "c" fn kx_tcp_close(fd: i32) void;

pub extern "c" fn kx_clipboard_set(text: [*:0]const u8) bool;
