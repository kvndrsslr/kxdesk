//! The bar's audio spectrum: a window of mono samples becomes one level per band.
//!
//! A Hann window and a radix-2 FFT of the whole window, then the bins folded into
//! bands that grow geometrically with frequency - music is heard in octaves, so
//! an octave of hiss takes as much of the bar as an octave of bass, which a
//! linear fold would not. A band's level is its loudest bin in decibels against
//! silence, moved by what the ear hears at the band's own frequency
//! (`weightingDb`) and mapped onto the graph's height, and it falls back over a
//! few frames rather than dropping the instant the note stops: at twenty frames a
//! second a bar that vanished at once would read as a flicker.
//!
//! `Silence` is the other half of that: the levels of a machine that stopped
//! playing are flat within a few frames, and what is left on the bar then is the
//! graph's own frame - the wash under the line - which an idle machine only ever
//! shows as an empty box.

const std = @import("std");

/// Samples one frame is taken from: 1024 at 48 kHz is 21 ms - a fifth of the
/// lowest band's period resolution is enough to separate the bass, and short
/// enough that the bars move with the music.
pub const window_size = 1024;

/// The bands a window is folded into, which is the item's own business to match
/// to its graph; `items_audio.zig` states how.
pub const bands = 59;

/// The lowest frequency the display covers, in Hz: the bottom of a bass
/// instrument's range, and low enough that the window's own resolution - a bin is
/// 47 Hz wide at 48 kHz - is what limits the lowest bands rather than this.
const low_hz = 40;

/// The highest, in Hz: above this is hiss and cymbal air, which one band of this
/// width cannot say anything about.
const high_hz = 16_000;

/// What reads as the bottom of the graph and what reads as the top, in dBFS,
/// before each band's own `weightingDb` moves them: a band quieter than its floor
/// is drawn empty, which is what silence and the noise floor of a machine playing
/// nothing both are; the ceiling is a few decibels below full scale, so that loud
/// music fills the graph without clipping against the top of it.
///
/// The weighting moves both ends by a whole spectrum's worth: the 40 Hz band's
/// floor is 34 dB further down than the kilohertz bands', which is where a bass
/// line of that band plays, and the top of the display only sits 7 dB lower.
const floor_db = -70;
const ceiling_db = -6;

/// How much a band falls between frames, in fractions of the graph's height:
/// loudness is read from a bar that has just been hit and is still falling, and
/// at twenty frames a second this clears a full-height peak in a third of a
/// second.
const fall_per_frame = 0.09;

/// How long a flat spectrum is still drawn before it is faded out, in
/// milliseconds: the levels go flat within `fall_per_frame`'s own decay of the
/// last note, so a second of that is a machine that has stopped rather than one
/// between two notes, and the room the item keeps is empty for the rest of the
/// gap.
pub const quiet_ms: i64 = 1_000;

/// How long the fade takes once it starts, in milliseconds: half a second is
/// ten of the item's frames, which is a fade rather than a cut.
pub const fade_ms: i64 = 500;

/// The twiddles of the window's FFT, `exp(-2*pi*i*k/N)`, as real and imaginary
/// pairs - fixed by the window size, so built once at compile time.
const twiddles = blk: {
    @setEvalBranchQuota(100_000);
    var table: [window_size / 2][2]f32 = undefined;
    for (&table, 0..) |*twiddle, k| {
        const angle = -2.0 * std.math.pi * @as(f64, @floatFromInt(k)) / window_size;
        twiddle.* = .{ @floatCast(@cos(angle)), @floatCast(@sin(angle)) };
    }
    break :blk table;
};

/// The levels a window is drawn as, and the state that keeps them from blinking:
/// the previous frame is what each band only ever falls from.
pub const Span = struct {
    /// The levels of the last frame, the fractions of the graph's height the bars
    /// were drawn at. Zero before a first window.
    levels: [bands]f64 = @splat(0),

    /// The levels `samples` draws, in `bands` fractions of the graph's height,
    /// oldest reading of a band's own decay included.
    ///
    /// `samples` is one window at `rate` Hz - `window_size` mono samples, the
    /// newest audio the tap has.
    pub fn analyse(self: *Span, samples: *const [window_size]f32, rate: f64) []const f64 {
        std.debug.assert(rate > 0);

        var real: [window_size]f32 = undefined;
        var imaginary: [window_size]f32 = @splat(0);
        for (0..window_size) |index| {
            // Hann, which costs the least leakage for a window this short: a tone
            // between two bins spreads over three of them rather than across the
            // whole spectrum.
            const index_float: f64 = @floatFromInt(index);
            const taper = 0.5 - 0.5 * @cos(2.0 * std.math.pi * index_float / window_size);
            real[index] = samples[index] * @as(f32, @floatCast(taper));
        }

        fft(&real, &imaginary);

        // The band's loudest bin, as an amplitude of one. The factor undoes the
        // FFT's own scaling (a magnitude of `N/2` per unit amplitude) and the
        // window's coherent gain (Hann halves a tone's amplitude), so that a
        // full-scale tone reads 0 dB.
        const scale = 4.0 / @as(f64, window_size);
        for (0..bands) |band| {
            const range = Band.of(rate, band);
            var magnitude: f64 = 0;
            if (range.centre) |position| {
                // Narrower than the FFT can resolve: read at the band's own
                // centre, between the two bins either side of it.
                const lower: usize = @intFromFloat(@floor(position));
                const fraction = position - @floor(position);
                const upper = @min(lower + 1, window_size / 2 - 1);
                const at_lower = binMagnitude(&real, &imaginary, lower);
                const at_upper = binMagnitude(&real, &imaginary, upper);
                magnitude = at_lower + (at_upper - at_lower) * fraction;
            } else {
                for (range.first..range.past) |bin| {
                    magnitude = @max(magnitude, binMagnitude(&real, &imaginary, bin));
                }
            }

            // A band with no signal at all is 20*log10(0) = -inf, which the
            // comparison below reads as the floor - the same place a band the
            // floor's own width below is drawn. The band's own weight is what
            // turns that reading of its energy into a reading of its loudness.
            const db = 20.0 * @log10(@max(magnitude * scale, 1e-9)) + weightingDb(range.hz);
            const wanted = std.math.clamp((db - floor_db) / (ceiling_db - floor_db), 0, 1);
            self.levels[band] = @max(wanted, self.levels[band] - fall_per_frame);
        }
        return &self.levels;
    }
};

/// What is left of the item when the machine stops playing: the opacity its
/// colours are drawn at, and the state that says when the spectrum went flat.
///
/// A level of zero is a band below the floor, so a frame of nothing but zeroes
/// is a spectrum with no sound in it at all; the quiet stretch is counted from
/// the frame that first reads so, which is within the decay of the last note.
/// The fade is a reading of the time since then rather than a count of the
/// frames drawn since it, so a frame the loop was late for lands where the fade
/// is rather than a step behind it.
///
/// The way back is not a fade: a frame with sound in it is drawn at full opacity
/// at once, since a fade in would dim the opening of the piece being played -
/// nothing is being hidden while there is something to show.
pub const Silence = struct {
    /// When the levels last went flat, zero while they are not. Only the newest
    /// quiet stretch is measured, so a frame with sound in it clears it.
    flat_since: i64 = 0,

    /// The opacity a frame of `levels` at `now` is drawn at: one until the flat
    /// spectrum has stood for `quiet_ms`, then falling to zero over `fade_ms`.
    pub fn opacity(self: *Silence, levels: []const f64, now: i64) f64 {
        if (sounding(levels)) {
            self.flat_since = 0;
            return 1;
        }
        if (self.flat_since == 0) self.flat_since = now;

        const flat_for = now - self.flat_since;
        if (flat_for < quiet_ms) return 1;
        const faded = @as(f64, @floatFromInt(flat_for - quiet_ms)) / fade_ms;
        return @max(0, 1 - faded);
    }
};

/// Whether a frame's levels carry sound: any band above the floor is a band with
/// music in it.
fn sounding(levels: []const f64) bool {
    for (levels) |level| if (level > 0) return true;
    return false;
}

/// The A-weighting curve of IEC 61672 at `hz` Hz, in dB: the gain the ear does
/// not apply, so that a band's level plus its weight is how loud the band is
/// heard rather than how much energy it carries.
///
/// It is the curve of equal loudness at low levels, and it is the tilt a
/// spectrum display needs: music carries far more energy an octave down - a bass
/// line reads tens of decibels hotter than a cymbal in the bins themselves -
/// while the ear hears 40 Hz as 34 dB quieter than 1 kHz at the same level, and
/// 3 kHz a decibel louder. An unweighted display is therefore a wall of bass with
/// a thin line above it, and this is what makes the display move with the mix
/// instead.
fn weightingDb(hz: f64) f64 {
    const square = hz * hz;
    const air_square = 12194.0 * 12194.0;

    // The standard's own transfer function, magnitude in amplitude of one.
    const numerator = air_square * square * square;
    const denominator = (square + 20.6 * 20.6) * @sqrt((square + 107.7 * 107.7) * (square + 737.9 * 737.9)) * (square + air_square);

    // The +2 dB is the standard's own reference: a kilohertz reads zero.
    return 20.0 * @log10(numerator / denominator) + 2.0;
}

/// The magnitude of one FFT bin, in amplitude units of the windowed samples.
fn binMagnitude(real: *const [window_size]f32, imaginary: *const [window_size]f32, bin: usize) f64 {
    const re: f64 = real[bin];
    const im: f64 = imaginary[bin];
    return @sqrt(re * re + im * im);
}

/// One band's bins: where the FFT's own bins land in the geometric scale the
/// bands are drawn on.
const Band = struct {
    /// The lowest and highest bin the band is read from, `first .. past`.
    first: usize,
    past: usize,
    /// The band's own centre frequency, in Hz: the geometric mean of its edges,
    /// because a band is a share of the octave above it and pitch is heard
    /// logarithmically. This is the frequency the band is weighted at.
    hz: f64,
    /// Where that centre sits, as a fractional bin, when the band is narrower
    /// than the FFT can resolve - and `null` when it spans at least one whole bin
    /// and is read from the bins themselves.
    ///
    /// The bottom of the display is finer than the transform: at 48 kHz a bin is
    /// 47 Hz wide, and twenty of the lowest bands are narrower than that, so
    /// reading their bins directly would draw them as one flat shelf - the same
    /// bin, seven times over, wherever a shelf is not the music. A band that
    /// narrow is read where it actually sits instead, between the two bins either
    /// side of its centre, which is what an analyser drawing a log scale does
    /// with a window this short.
    centre: ?f64,

    /// The band `band`'s bins at `rate` Hz.
    ///
    /// The band's edges are placed in Hz - one geometric series whatever the
    /// machine's rate - and then read as bins, rounded up so that the bins the
    /// bands are cut into tile the spectrum without touching: a bin belongs to
    /// the band whose own range it falls in, which is what makes a tone's band a
    /// reading of its frequency.
    fn of(rate: f64, band: usize) Band {
        const bin_hz = rate / window_size;
        const low = edgeHz(rate, band);
        const high = edgeHz(rate, band + 1);
        const first = binAt(rate, low);
        const past = @max(binAt(rate, high), first + 1);
        const hz = @sqrt(low * high);

        return .{
            .first = first,
            .past = past,
            .hz = hz,
            .centre = if (high - low < bin_hz)
                std.math.clamp(hz / bin_hz, 1, window_size / 2 - 1)
            else
                null,
        };
    }

    /// The band's own range, for anything that has to name what a band is.
    pub fn rangeHz(rate: f64, band: usize) [2]f64 {
        return .{ edgeHz(rate, band), edgeHz(rate, band + 1) };
    }

    /// The frequency `band`'s lower edge sits at, and, for `bands`, the display's
    /// own top: the bands are one geometric series, so band n's start is band
    /// n-1's end and there is no frequency between two bands.
    fn edgeHz(rate: f64, edge: usize) f64 {
        // A machine playing at 22 kHz has nothing to show above its own Nyquist,
        // and the bins above it are the mirror of the ones below.
        const top = @min(high_hz, rate / 2);
        const step = std.math.pow(f64, top / low_hz, 1.0 / @as(f64, bands));
        return low_hz * std.math.pow(f64, step, @floatFromInt(edge));
    }

    /// The FFT bin an edge falls in, held inside the bins that carry signal:
    /// bin 0 is the window's own mean, and the top bin is the one at Nyquist.
    ///
    /// Rounded up, so that the bins the bands are cut into tile the spectrum
    /// without touching: a bin belongs to the band whose own range it falls in,
    /// which is what makes a tone's band a reading of its frequency.
    fn binAt(rate: f64, hz: f64) usize {
        const bin: usize = @intFromFloat(@ceil(hz / (rate / window_size)));
        return std.math.clamp(bin, 1, window_size / 2 - 1);
    }
};

/// One band's frequency range, in Hz - see `Band.rangeHz`.
pub const bandRangeHz = Band.rangeHz;

/// In-place radix-2 Cooley-Tukey: the window's 1024 bins in `real` and
/// `imaginary`, in the order the bins come in (no `fftshift`), so bin `k` is
/// `k * rate / window_size` Hz.
fn fft(real: *[window_size]f32, imaginary: *[window_size]f32) void {
    // Bit-reversed order first, which is what lets the combinations below work
    // in place: the counter is carried forward rather than recomputed per index.
    var reversed_index: usize = 0;
    for (1..window_size) |index| {
        var bit: usize = window_size >> 1;
        while (reversed_index & bit != 0) : (bit >>= 1) reversed_index ^= bit;
        reversed_index |= bit;
        if (index < reversed_index) {
            std.mem.swap(f32, &real[index], &real[reversed_index]);
            std.mem.swap(f32, &imaginary[index], &imaginary[reversed_index]);
        }
    }

    // Then the butterflies, in groups of two, four, eight and so on up to the
    // whole window: each pass combines two groups of half its size into one.
    var group: usize = 2;
    while (group <= window_size) : (group <<= 1) {
        const half = group >> 1;
        const twiddle_step = window_size / group;
        var start: usize = 0;
        while (start < window_size) : (start += group) {
            for (0..half) |k| {
                const twiddle = twiddles[k * twiddle_step];
                const second_real = real[start + k + half];
                const second_imaginary = imaginary[start + k + half];
                const product_real = second_real * twiddle[0] - second_imaginary * twiddle[1];
                const product_imaginary = second_real * twiddle[1] + second_imaginary * twiddle[0];

                real[start + k + half] = real[start + k] - product_real;
                imaginary[start + k + half] = imaginary[start + k] - product_imaginary;
                real[start + k] += product_real;
                imaginary[start + k] += product_imaginary;
            }
        }
    }
}
