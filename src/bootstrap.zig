//! The bootstrap names the daemon registers and every client looks up: one
//! receive port, two names - the bar's `mach_helper` events and the CLI's
//! control channel.
//!
//! `KXDESK_BOOTSTRAP` replaces the base (`org.kdressler.kxdesk`), so a checkout
//! daemon and the client that talks to it can run beside the installed service.
//! A daemon started that way is a probe, and `main.zig` leaves the live bar, the
//! key bindings and the grabber to the installed daemon: pointing SketchyBar's
//! items at a name that dies with the probe is exactly what a probe must not do.

const std = @import("std");

const platform = @import("platform.zig");

/// The base the installed service registers, and the value every item carries
/// as `mach_helper`.
pub const default_base = "org.kdressler.kxdesk";

/// Longest base the environment may name. Both derived names share a buffer, so
/// a longer one is ignored rather than truncated into a name nothing answers.
const max_base = 200;

var event_buffer: [max_base + 1]u8 = undefined;
var control_buffer: [max_base + 1 + ".control".len]u8 = undefined;

/// The bar's `mach_helper` name: what an item routes its events to.
pub var event: [:0]const u8 = default_base;

/// The CLI's control name: what a client sends its request to.
pub var control: [:0]const u8 = default_base ++ ".control";

/// Whether the environment named another base. A daemon started with one is a
/// probe and keeps its hands off the installed daemon's bar and bindings.
pub var overridden = false;

/// Derive both names, from `KXDESK_BOOTSTRAP` when it holds a usable base.
///
/// Called once from `main`, before anything registers or looks a name up, and
/// again by tests: every call recomputes from the environment, so an unset or
/// empty variable is the installed names.
pub fn resolve() void {
    overridden = false;
    event = default_base;
    control = default_base ++ ".control";

    var raw: [max_base + 1]u8 = undefined;
    if (!platform.kx_env("KXDESK_BOOTSTRAP", &raw, raw.len)) return;
    const base = std.mem.sliceTo(&raw, 0);
    if (base.len == 0 or base.len > max_base) return;

    @memcpy(event_buffer[0..base.len], base);
    event_buffer[base.len] = 0;
    event = event_buffer[0..base.len :0];

    @memcpy(control_buffer[0..base.len], base);
    @memcpy(control_buffer[base.len..][0..".control".len], ".control");
    control_buffer[base.len + ".control".len] = 0;
    control = control_buffer[0 .. base.len + ".control".len :0];
    overridden = true;
}
