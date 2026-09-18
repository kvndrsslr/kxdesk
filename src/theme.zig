//! Visual constants: palette, fonts, glyphs and spacing.
//!
//! This replaces `colors.sh` / `icons.sh`. Values are plain data so that item
//! definitions in `bar.zig` read like the declarative configuration they are.

/// ARGB colour, as SketchyBar spells it: `0xAARRGGBB`.
pub const Color = u32;

pub const black: Color = 0xff1e2121;
pub const white: Color = 0xffd5c4a1;
pub const red: Color = 0xfffa4934;
pub const green: Color = 0xffb8bb27;
pub const blue: Color = 0xff82a498;
pub const yellow: Color = 0xfffabd2f;
pub const orange: Color = 0xfffe8019;
pub const magenta: Color = 0xffd3869b;
pub const grey: Color = 0xffa89983;
pub const dark_grey: Color = 0xff7c6f64;
pub const dark_green: Color = 0xff79740e;
pub const aqua: Color = 0xff8ec07c;

pub const bar_color: Color = black;
pub const icon_color: Color = white;
pub const label_color: Color = white;
pub const background_1: Color = 0xff282828;
pub const background_2: Color = 0xff3c3836;

/// Space label background while the space is visible but not focused.
pub const space_visible: Color = 0xff504945;
/// Calendar icon colour, kept as a literal in the shell config.
pub const calendar_icon: Color = dark_grey;
/// Separator icon colour.
pub const separator_icon: Color = background_2;

/// Bar geometry.
pub const bar_height: u32 = 24;
pub const padding: u32 = 3;

pub const font = "JetBrainsMono Nerd Font";
pub const app_font = "sketchybar-app-font";

/// Glyphs, named after the shell variables they replace.
pub const glyph = struct {
    pub const loading = "\u{100587}";
    pub const bell = "\u{1002da}";
    pub const bell_dot = "\u{100757}";
    pub const brew = "\u{10041b}";
    /// Shown by the brew item when nothing is outdated.
    pub const brew_current = "\u{100185}";
    /// Stands in for a notification whose title mentions a break or deprecation.
    pub const github_important = "\u{10005e}";

    /// Provider balances: the power bolt for NeuralWatt, whose pitch is energy
    /// (and which the battery item already draws when charging, so it is proven
    /// at this weight), and exchange arrows for OpenRouter.
    ///
    /// Both were checked by rendering them: a Nerd Font codepoint can be
    /// "present" according to the font's character map and still draw nothing,
    /// which several of the router and network candidates did.
    pub const neuralwatt = "\u{f0e7}";
    pub const openrouter = "\u{f074}";

    pub const git_issue = "\u{100377}";
    pub const git_discussion = "\u{1004a4}";
    pub const git_pull_request = "\u{100661}";
    pub const git_commit = "\u{10085a}";
    pub const separator = "\u{f054}";

    pub const battery_full = "\u{f240}";
    pub const battery_3 = "\u{f241}";
    pub const battery_2 = "\u{f242}";
    pub const battery_1 = "\u{f243}";
    pub const battery_empty = "\u{f244}";
    pub const battery_charging = "\u{f0e7}";

    pub const yabai_stack = "\u{1003ed}";
    pub const yabai_fullscreen_zoom = "\u{1003dc}";
    pub const yabai_parent_zoom = "\u{100943}";
    pub const yabai_float = "\u{10088c}";
    pub const yabai_grid = "\u{100933}";

};
