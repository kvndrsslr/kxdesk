//! Thin Zig bindings for `src/platform.m`.
//!
//! All Mach, Objective-C and libc contact happens through this module; the rest
//! of the daemon is platform-free logic that can be reasoned about (and tested)
//! on its own.

/// A received block handed to the server: either a NUL-separated
/// `key\0value\0...\0` event, a `CMD\0verb\0...` request, or SketchyBar's bare
/// `k` marker. Only valid for the duration of the call. `reply_port` is 0 for
/// SketchyBar's one-way sends and must be `sb_port_copy`ed to outlive the call.
pub const Handler = *const fn (block: [*:0]const u8, reply_port: u32) callconv(.c) void;

pub extern "c" fn sb_bootstrap_lookup(name: [*:0]const u8) u32;
pub extern "c" fn sb_port_release(port: u32) void;
pub extern "c" fn sb_server_register(name: [*:0]const u8) u32;
pub extern "c" fn sb_server_serve(port: u32, handler: Handler) void;
pub extern "c" fn sb_send(
    port: u32,
    argv: [*]const u8,
    len: usize,
    out: ?[*]u8,
    cap: usize,
    timeout_ms: u32,
) i32;
pub extern "c" fn sb_post(port: u32, argv: [*]const u8, len: usize) i32;
pub extern "c" fn sb_port_copy(port: u32) u32;
pub extern "c" fn sb_server_publish(port: u32, name: [*:0]const u8) bool;
pub extern "c" fn sb_uid() u32;

pub extern "c" fn sb_exec_capture(
    argv: [*]const ?[*:0]const u8,
    out: [*]u8,
    cap: usize,
) i64;

pub extern "c" fn sb_exec_status(argv: [*]const ?[*:0]const u8) i32;

pub extern "c" fn sb_which(name: [*:0]const u8, out: [*]u8, cap: usize) bool;

pub extern "c" fn sb_env(name: [*:0]const u8, out: [*]u8, cap: usize) bool;
pub extern "c" fn sb_app_font_path(out: [*]u8, cap: usize) bool;
pub extern "c" fn sb_battery(percent: *i32, charging: *bool) bool;
pub extern "c" fn sb_clock(
    icon: [*]u8,
    icon_cap: usize,
    label: [*]u8,
    label_cap: usize,
) void;

pub extern "c" fn sb_osa_compile(source: [*:0]const u8, language: [*:0]const u8) ?*anyopaque;
pub extern "c" fn sb_osa_run(script: *anyopaque, out: ?[*]u8, cap: usize) bool;
pub extern "c" fn sb_osa_release(script: *anyopaque) void;
pub extern "c" fn sb_open_url(url: [*:0]const u8) bool;
pub extern "c" fn sb_self_path(out: [*]u8, cap: usize) bool;
