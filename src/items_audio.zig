//! The audio spectrum item: one frame of the machine's own output audio, drawn
//! as a spectrum rather than as a series over time.
//!
//! Every frame pushes one value per graph column, so the graph's whole width is
//! replaced at once and nothing scrolls: the columns are the bands, lowest
//! frequency on the left, not the last minute. The tap itself is the platform's
//! (`kx_audio_*` in `src/platform.m`), and it is started from a task of its own
//! because the call that starts it waits for the system's permission prompt.
//!
//! A frame carries the item's colours as well as its values, faded by
//! `spectrum.Silence`: the block goes invisible a second after the spectrum
//! went flat, and is drawn whole again the frame a sound arrives.

const std = @import("std");

const background = @import("background.zig");
const log = @import("log.zig");
const platform = @import("platform.zig");
const Props = @import("props.zig").Props;
const sb = @import("sb.zig");
const spectrum = @import("spectrum.zig");
const style = @import("style.zig");
const theme = @import("theme.zig");

/// The bar item the spectrum is drawn on.
pub const item = "audio.spectrum";

/// The values one frame pushes, which is also the graph's own column count: the
/// bands, and the value the item's draw starts its path at.
///
/// This item sits in the notch's right-hand section, and SketchyBar sets a
/// graph's `rtl` only for the right and center-left positions (`bar.c`), so this
/// graph is drawn left to right: it moves to `y[0]` at the left edge and then
/// paints `y[width - 1]` through `y[1]` away from it (`graph.c`). The value the
/// path starts at therefore lands on the column under `y[width - 1]`, and the
/// graph's own last column is never painted at all. Pushing the graph's whole
/// width every frame is what keeps that alignment - each frame overwrites every
/// value the last one left - and it is why a frame carries the lowest band twice:
/// once as the value the path starts at, and once as the column below it, where
/// the frame's second value begins.
pub const values = spectrum.bands + 1;

/// How often a frame is drawn. Twenty a second is what makes the bars move with
/// a note rather than after it; a frame is one small batch to the bar.
const cadence_ms: i64 = 50;

/// How long a tap that would not start is left alone before it is built again.
/// The one reason it fails is the system's audio recording permission, granted
/// from System Settings: there is no event to say it happened, and the machine is
/// worth asking again for the rest of the day.
const retry_ms: i64 = 30_000;

/// What a tap that will not start is worth saying: the permission is the one
/// thing about it the person reading the log can act on.
const complaint =
    "the audio spectrum has no tap: grant \"System Audio Recording\" to kxdesk " ++
    "in System Settings > Privacy & Security, then restart the daemon";

/// The updater: the item's frame clock, the window it analyses, and the tap.
pub const Updater = struct {
    bar: *sb.Client,
    /// The bars' levels, which each band only ever falls from.
    span: spectrum.Span = .{},
    /// When the spectrum went flat, and so how far the block has been faded out
    /// since - see `spectrum.Silence`.
    silence: spectrum.Silence = .{},
    /// The tap's start, at most one in flight. It is the call that blocks, so it
    /// never runs on the receive loop this is polled from.
    tap: background.Slot = .{},
    /// When the last frame was drawn, zero until one is.
    last_frame: i64 = 0,
    /// When the tap was last asked for, so a failure is not retried every frame.
    last_attempt: i64 = 0,
    /// The one message about a tap that will not start, said once.
    complaint: log.Once = .{},
    /// The window the tap's newest audio is copied into.
    window: [spectrum.window_size]f32 = undefined,

    pub fn init(bar: *sb.Client) Updater {
        return .{ .bar = bar };
    }

    /// Draw one frame if the cadence says one is due, and report what the receive
    /// loop may wait next. Called from that loop's timer.
    ///
    /// The tap is started here the first time - off the loop, since the system's
    /// permission prompt blocks whoever asks for it - and asked for again while
    /// it is not running.
    pub fn poll(self: *Updater, io: std.Io, bar: ?*sb.Client) u32 {
        const now = nowMs(io);

        switch (status()) {
            .running => {},
            .failed => {
                if (self.complaint.changed(complaint)) log.warn("{s}", .{complaint});
                self.askForTap(io, now);
                return @intCast(cadence_ms);
            },
            // An attempt is in flight: whether the prompt has been answered is
            // not this side's to know, only the answer is.
            .starting, .off => {
                self.askForTap(io, now);
                return @intCast(cadence_ms);
            },
        }

        if (!self.due(now)) return @intCast(cadence_ms);
        self.last_frame = now;

        // Nothing is analysed for a bar that is not there to draw it, but the
        // clock has moved on either way: the next frame is one cadence after this
        // one, not a burst of the frames that were missed.
        const client = bar orelse return @intCast(cadence_ms);
        const rate = platform.kx_audio_rate();
        if (rate <= 0 or !platform.kx_audio_window(&self.window, self.window.len)) {
            return @intCast(cadence_ms);
        }

        // A bar that will not take the frame is on its way out: the next one
        // describes the audio as it is then, and that is all that is owed.
        const levels = self.span.analyse(&self.window, rate);
        push(client, levels, self.silence.opacity(levels, now)) catch {};
        return @intCast(cadence_ms);
    }

    /// Whether the frame cadence has run out since the last frame was drawn.
    fn due(self: *const Updater, now: i64) bool {
        if (self.last_frame == 0) return true;
        return now - self.last_frame >= cadence_ms;
    }

    /// Ask for the tap, unless one was asked for too recently to bother again.
    fn askForTap(self: *Updater, io: std.Io, now: i64) void {
        if (self.last_attempt != 0 and now - self.last_attempt < retry_ms) return;
        self.last_attempt = now;
        self.tap.request(io, startTap, .{});
    }
};

/// The properties one frame sets: the block's two colours, faded to the frame's
/// `opacity`. Split from `push` so that the keys the item is drawn with are the
/// item declaration's to state and a test's to pin.
pub fn frameProps(props: *Props, opacity: f64) !void {
    try props.write(.{ .graph = .{
        .color = try props.argb(style.faded(theme.graph_spectrum, opacity)),
        .fill_color = try props.argb(style.faded(theme.graph_spectrum_fill, opacity)),
    } });
}

/// One frame in the order this item's own draw reads it: the value the path starts
/// at, then the bands highest first.
///
/// The draw starts at the left edge with `y[0]` and paints `y[width - 1]` first
/// (`graph.c`), so the lowest band has to be both the value the path starts at
/// and the value at the far end of the frame: that is what paints it on the left
/// edge, with the highest band one column in from the right. The start repeats
/// the lowest band because both are drawn on the same column - a start that
/// disagreed with the column under it would draw a spike there.
pub fn frameOrder(levels: []const f64) [values]f64 {
    std.debug.assert(levels.len + 1 == values);

    var frame: [values]f64 = undefined;
    frame[0] = levels[0];
    for (frame[1..], 0..) |*value, position| value.* = levels[levels.len - 1 - position];
    return frame;
}

/// Hand one frame to the bar: the graph's whole width, in one batch, so the
/// spectrum is never drawn half of one frame and half of the next.
///
/// The block's opacity rides on the frame as the alpha of the two colours it is
/// drawn with - the line and the wash under it, which is the whole of the block:
/// its background is `style.graph_fill`, which is transparent. Both are stated
/// every frame rather than only while faded, so that the colours a `reload`
/// restates are the frame's to correct, the way its values are.
fn push(client: *sb.Client, levels: []const f64, opacity: f64) !void {
    std.debug.assert(levels.len + 1 == values);

    var props: Props = .{};
    try frameProps(&props, opacity);
    try client.set(item, props.slice());

    // Every value the frame has, in the order the item's draw reads them, from the
    // column the path starts at to the far end of the item.
    for (frameOrder(levels)) |level| try client.push(item, level);
    try client.commit();
}

/// Start the tap, as a task of its own: the call blocks while the system puts up
/// its permission prompt, and the receive loop must keep running meanwhile.
fn startTap() background.Result {
    if (platform.kx_audio_start()) return;
    return error.NoAudioTap;
}

/// The tap's state, read from an integer that is only ever one of `AudioStatus`.
fn status() platform.AudioStatus {
    return std.enums.fromInt(platform.AudioStatus, platform.kx_audio_status()) orelse .failed;
}

/// Milliseconds on the wall clock, the unit the frame cadence is kept in.
fn nowMs(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Timestamp.now(io, .real).nanoseconds, std.time.ns_per_ms));
}
