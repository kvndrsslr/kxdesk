const std = @import("std");

/// The commit `build.zig.zon` pins the hotkey engine at, reported by
/// `kxdesk hotkey status` so a running daemon says which code it is.
const engine_pin = "f359304";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // kxdesk sits on the bar's event path, so an optimized build is the default;
    // `-Doptimize=Debug` still works for debugging.
    const optimize = b.option(
        std.lang.Optimize,
        "optimize",
        "Optimization mode (default: fast)",
    ) orelse .fast;

    const src = sources(b, b.dependency("skhd_zig", .{}));
    // The two bundles' Info.plists, written from here rather than shipped as files:
    // each holds the identifier the grants are keyed to, which belongs next to the
    // bundle layout it describes.
    const plists = b.addWriteFiles();

    const exe = b.addExecutable(.{
        .name = "kxdesk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    wire(b, exe.root_module, target, optimize, &src);

    // The root daemon the tap-hold rules need; inert unless one is declared in
    // `skhdrc`, installed by `kxdesk grabber install` (root), not by the daemon itself.
    const grabber_exe = b.addExecutable(.{
        .name = "kxdesk-grabber",
        .root_module = grabber(b, target, optimize, &src),
    });
    b.installArtifact(grabber_exe);

    // The grabber's bundle: the shape its Input Monitoring grant needs. A root
    // LaunchDaemon cannot raise the approval dialog, so the entry is added by hand,
    // and the pane needs an app to add.
    app(b, "kxdesk-grabber", grabber_exe, plists.add("grabber.plist",
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>org.kdressler.kxdesk.grabber</string>
        \\    <key>CFBundleName</key>
        \\    <string>kxdesk-grabber</string>
        \\    <key>CFBundleExecutable</key>
        \\    <string>kxdesk-grabber</string>
        \\    <key>CFBundlePackageType</key>
        \\    <string>APPL</string>
        \\    <key>LSMinimumSystemVersion</key>
        \\    <string>13.0</string>
        \\    <!-- A daemon: launchd starts it, and nothing about it is a UI. -->
        \\    <key>LSUIElement</key>
        \\    <true/>
        \\</dict>
        \\</plist>
        \\
    ), null);

    // `kxdesk version` reports the version the binary was built from, so it is
    // read out of the manifest here and injected as a build option: build.zig.zon
    // stays the one place it is written down.
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifestVersion(b));
    exe.root_module.addOptions("build_options", options);

    b.installArtifact(exe);

    app(b, "kxdesk", exe, plists.add("kxdesk.plist",
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>org.kdressler.kxdesk</string>
        \\    <key>CFBundleName</key>
        \\    <string>kxdesk</string>
        \\    <key>CFBundleExecutable</key>
        \\    <string>kxdesk</string>
        \\    <key>CFBundlePackageType</key>
        \\    <string>APPL</string>
        \\    <key>LSMinimumSystemVersion</key>
        \\    <string>13.0</string>
        \\    <!-- An agent: no Dock icon, no menu bar, no window. -->
        \\    <key>LSUIElement</key>
        \\    <true/>
        \\    <!-- The icon the Accessibility pane shows; `assets/kxdesk.icns` is
        \\         composed from the SVG beside it, recipe in that file. -->
        \\    <key>CFBundleIconFile</key>
        \\    <string>kxdesk</string>
        \\</dict>
        \\</plist>
        \\
    ), b.path("assets/kxdesk.icns"));

    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    wire(b, t.root_module, target, optimize, &src);

    const run = b.addRunArtifact(t);
    b.step("test", "Run unit tests").dependOn(&run.step);
}

/// Everything a kxdesk module is built against: the platform seam in
/// `platform.m`, the frameworks it and the bar client use, SQLite, and the
/// embedded hotkey engine.
fn wire(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    src: *const Sources,
) void {
    // SQLite is bound through its C interface: the standard library has no
    // SQLite any more, so the SDK header is translated into a Zig module here
    // and linked against the copy macOS ships - which needs no dependency, and
    // is newer than the Homebrew one besides.
    const sqlite = b.addTranslateC(.{
        .root_source_file = b.path("vendor/sqlite.h"),
        .target = target,
        .optimize = optimize,
    });
    mod.addImport("sqlite", sqlite.createModule());
    mod.linkSystemLibrary("sqlite3", .{});

    // The upstream SketchyBar header is compiled into the helper: it defines the
    // mach wire format as `static inline` functions, so `platform.m` including it
    // statically links it here.
    mod.addIncludePath(b.path("vendor"));
    mod.addIncludePath(b.path("src"));
    mod.addCSourceFile(.{
        .file = b.path("src/platform.m"),
        .flags = &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Wno-unused-parameter" },
    });
    mod.linkFramework("AppKit", .{});
    // The audio spectrum's tap: a process tap on the machine's own output, which
    // is one HAL object and one aggregate device carrying it.
    mod.linkFramework("CoreAudio", .{});
    mod.linkFramework("CoreFoundation", .{});
    // CoreText locates the installed app font; the font itself describes the
    // application -> icon mapping that the helper reads at startup.
    mod.linkFramework("CoreText", .{});
    mod.linkFramework("Foundation", .{});
    mod.linkFramework("IOKit", .{});
    // SystemConfiguration answers which interface carries the internet, for the
    // link icon; it is the store `scutil` prints, not a probe.
    mod.linkFramework("SystemConfiguration", .{});

    mod.addImport("skhd", engine(b, target, optimize, src));
}

/// The hotkey engine: upstream skhd.zig, built as a module of this binary.
///
/// Zig cannot write into a dependency, so the pinned `src/` is copied into the
/// build cache and one file of the copy is rewritten - `engine_delta` is the
/// whole difference, kept small so it reads as the upstream patch it is meant to
/// become. A dependency's own `build.zig` is not run, so the glue it would have
/// supplied is recreated here: the `grabber_protocol` module, the `VERSION` and
/// `build_options` anonymous imports, and the frameworks the event tap and its
/// Carbon glue link against.
fn engine(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    src: *const Sources,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = src.agent,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("grabber_protocol", b.createModule(.{
        .root_source_file = src.protocol,
        .target = target,
        .optimize = optimize,
    }));
    module.addAnonymousImport("VERSION", .{ .root_source_file = src.version });
    module.addOptions("build_options", src.options);

    // The agent's set: the tap is CoreGraphics through ApplicationServices, the
    // hotkey registration is Carbon's, and the service queries are
    // ServiceManagement's.
    module.linkFramework("Cocoa", .{});
    module.linkFramework("Carbon", .{});
    module.linkFramework("CoreServices", .{});
    module.linkFramework("ServiceManagement", .{});
    module.linkFramework("IOKit", .{});
    return module;
}

/// The grabber: the root daemon upstream builds beside the agent, and the half
/// that implements tap-hold. It is only needed for `.remap … { tap, hold }`
/// rules, which an event tap cannot do - seizing the keyboard and injecting
/// through a virtual HID device is what they take.
///
/// Its install plumbing is upstream's own binary's (`--install-grabber`, whose
/// plists live in the `scripts/` the pinned package omits), so how it is started
/// is this repo's business: `kxdesk grabber install`, in `src/grabber.zig`.
fn grabber(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    src: *const Sources,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = src.grabber,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("grabber_protocol", b.createModule(.{
        .root_source_file = src.protocol,
        .target = target,
        .optimize = optimize,
    }));
    module.addAnonymousImport("VERSION", .{ .root_source_file = src.version });
    module.addOptions("build_options", src.options);

    // Upstream's set for this half: IOKit to seize and to enumerate, CoreGraphics
    // for the virtual-HID injection, SystemConfiguration for the console user.
    module.linkFramework("IOKit", .{});
    module.linkFramework("CoreFoundation", .{});
    module.linkFramework("CoreGraphics", .{});
    module.linkFramework("SystemConfiguration", .{});
    return module;
}

/// The pinned engine materialized once for both binaries: its `src/` copied into
/// the build cache, one file rewritten, a `VERSION` file, and the
/// `build_options` upstream's own build would have generated.
const Sources = struct {
    /// The agent's root: upstream's `src/skhd.zig` with `engine_delta` applied.
    agent: std.Build.LazyPath,
    /// The grabber's root, taken from the same copy.
    grabber: std.Build.LazyPath,
    protocol: std.Build.LazyPath,
    version: std.Build.LazyPath,
    options: *std.Build.Step.Options,
};

fn sources(b: *std.Build, dep: *std.Build.Dependency) Sources {
    const tree = b.addWriteFiles();
    _ = tree.addCopyDirectory(dep.path("src"), "src", .{});
    const directory = tree.getDirectory();

    // Upstream's build writes these into its own builds; nothing in the agent's
    // or the grabber's analysis path reads more than `track_alloc`, and the
    // pinned dext is not installed by this binary.
    const options = b.addOptions();
    options.addOption(bool, "track_alloc", false);
    options.addOption([]const u8, "karabiner_dext_version", "");
    options.addOption([]const u8, "karabiner_dext_url", "");
    options.addOption([]const u8, "karabiner_dext_sha256", "");

    return .{
        .agent = tree.add("src/engine.zig", applyDelta(b, dep)),
        .grabber = directory.path(b, "src/grabber/main.zig"),
        .protocol = directory.path(b, "src/grabber_protocol.zig"),
        .version = tree.add("VERSION", engine_pin ++ "\n"),
        .options = options,
    };
}

/// One edit the embedded copy carries over the pinned source: `from` must occur
/// exactly once, so a pin bump that moves a patched line fails the build here
/// rather than as a compiler error in a copy nobody wrote.
const Edit = struct { from: []const u8, to: []const u8 };

/// Where the engine calls the shell, and where it changes mode, a host gets to
/// run the call itself instead. That is the whole delta: nothing in the parser,
/// the mappings or the event tap moves, so upstream's grammar is exactly what
/// `skhdrc` gets.
const engine_delta = [_]Edit{
    .{
        .from = "var hotload_refresh_pending: std.atomic.Value(bool) = .init(false);",
        .to =
        \\var hotload_refresh_pending: std.atomic.Value(bool) = .init(false);
        \\
        \\/// The way an action a hotkey matched is run. `shell` and `verbose` are
        \\/// what `Mappings` parsed and how this process was started, and `cmd` is
        \\/// the action line as the config wrote it. `cmd` is borrowed for the
        \\/// duration of the call only - the mappings it points into are freed by
        \\/// the next reload - so a hook that defers the work must copy it.
        \\pub const Dispatch = struct {
        \\    pub var run: *const fn (shell: [:0]const u8, verbose: bool, cmd: [:0]const u8) anyerror!void = defaultRun;
        \\
        \\    /// Upstream's behavior: hand the line to the user's shell.
        \\    pub fn defaultRun(shell: [:0]const u8, verbose: bool, cmd: [:0]const u8) anyerror!void {
        \\        return forkAndExec(shell, cmd, verbose);
        \\    }
        \\};
        \\
        \\/// The way a host hears that the current mode changed, so that what the
        \\/// engine reports can be shown somewhere else. Called after every write of
        \\/// the mode, with the mode's name, or "default" when there is none - which
        \\/// is what a config reload's reset says. The name is borrowed for the
        \\/// duration of the call only, for the same reason `Dispatch.run`'s line is.
        \\pub const ModeNotify = struct {
        \\    pub var run: *const fn (name: []const u8) void = noop;
        \\
        \\    fn noop(_: []const u8) void {}
        \\};
        \\
        \\/// The tap's key synthesizer, which upstream's own binary imports
        \\/// directly: a chord posted into the session, for a fallback that needs a
        \\/// key rather than a command.
        \\pub const synthesize = @import("synthesize.zig");
        ,
    },
    .{
        // The chord parser, so a host can say what its own keyspecs mean:
        // `ctrl - left` is not `ctrl - 0x7B`, and the difference is one
        // implicit-modifier table away. And the chord shape plus its flag
        // matcher, so a host can pin that what it writes by hand parses to
        // exactly what an identical live key press carries - including that
        // empty-flags config chords and no-modifier presses compare equal,
        // which is what the prefix lookup relies on.
        .from = "const Parser = @import(\"Parser.zig\");",
        .to = "pub const Parser = @import(\"Parser.zig\");\npub const HotkeyPress = @import(\"Hotkey.zig\").KeyPress;\npub const hotkeyFlagsMatch = @import(\"Hotkey.zig\").hotkeyFlagsMatch;",
    },
    .{
        .from = "try forkAndExec(self.mappings.shell, cmd, self.verbose);",
        .to = "try Dispatch.run(self.mappings.shell, self.verbose, cmd);",
    },
    .{
        .from = "try forkAndExec(self.mappings.shell, activation_cmd, self.verbose);",
        .to = "try Dispatch.run(self.mappings.shell, self.verbose, activation_cmd);",
    },
    .{
        .from = "try forkAndExec(self.mappings.shell, mode_cmd, self.verbose);",
        .to = "try Dispatch.run(self.mappings.shell, self.verbose, mode_cmd);",
    },
    .{
        .from =
        \\        if (self.mappings.mode_map.getPtr("default")) |m| {
        \\            self.current_mode = m;
        \\            log.info("layer push: exited to default", .{});
        \\        } else {
        \\            self.current_mode = null;
        \\        }
        ,
        .to =
        \\        if (self.mappings.mode_map.getPtr("default")) |m| {
        \\            self.setMode(m);
        \\            log.info("layer push: exited to default", .{});
        \\        } else {
        \\            self.setMode(null);
        \\        }
        ,
    },
    .{
        .from =
        \\    if (self.mappings.mode_map.getPtr(mode_name)) |m| {
        \\        self.current_mode = m;
        \\        log.info("layer push: entered '{s}'", .{mode_name});
        ,
        .to =
        \\    if (self.mappings.mode_map.getPtr(mode_name)) |m| {
        \\        self.setMode(m);
        \\        log.info("layer push: entered '{s}'", .{mode_name});
        ,
    },
    .{
        .from = "                self.current_mode = self.mappings.mode_map.getPtr(act.mode_name);",
        .to = "                self.setMode(self.mappings.mode_map.getPtr(act.mode_name));",
    },
    .{
        .from = "                    self.current_mode = self.mappings.mode_map.getPtr(\"default\");",
        .to = "                    self.setMode(self.mappings.mode_map.getPtr(\"default\"));",
    },
    .{
        .from =
        \\    // Reset to default mode
        \\    if (self.mappings.mode_map.getPtr("default")) |default_mode| {
        \\        self.current_mode = default_mode;
        \\    } else {
        \\        self.current_mode = null;
        \\    }
        ,
        .to =
        \\    // Reset to default mode
        \\    self.setMode(self.mappings.mode_map.getPtr("default"));
        ,
    },
    .{
        .from = "/// Poll AXIsProcessTrusted on a 1s timer and reconcile the event tap with",
        .to =
        \\/// The one place the current mode is written, so that every change is
        \\/// reported: entering a mode, a reload's reset and a layer the grabber
        \\/// pushed alike.
        \\fn setMode(self: *Skhd, mode: ?*Mode) void {
        \\    self.current_mode = mode;
        \\    ModeNotify.run(if (mode) |m| m.name else "default");
        \\}
        \\
        \\/// Poll AXIsProcessTrusted on a 1s timer and reconcile the event tap with
        ,
    },
};

/// The pinned engine source with `engine_delta` applied.
fn applyDelta(b: *std.Build, dep: *std.Build.Dependency) []const u8 {
    // Read at configure time, and say so: the copy above would otherwise be
    // built from a file this build script never looked at.
    b.dependOnFileContents(dep.path("src/skhd.zig"));
    const path = dep.builder.root.joinStringZ(b.allocator, "src/skhd.zig") catch
        @panic("engine source path could not be resolved");
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        b.graph.io,
        path,
        b.allocator,
        .unlimited,
        .of(u8),
        0,
    ) catch @panic("engine source could not be read");

    var patched: []const u8 = source;
    for (engine_delta, 0..) |edit, index| {
        const at = std.mem.indexOf(u8, patched, edit.from) orelse
            @panic(b.fmt("engine delta {d} does not fit the pinned source", .{index}));
        // Applied once, or the rest of the delta would silently address the
        // wrong copy of a line.
        if (std.mem.indexOfPos(u8, patched, at + edit.from.len, edit.from) != null)
            @panic(b.fmt("engine delta {d} matches more than once", .{index}));
        patched = b.fmt("{s}{s}{s}", .{
            patched[0..at], edit.to, patched[at + edit.from.len ..],
        });
    }
    return patched;
}

/// A `.app` around one of the binaries, staged in the prefix and signed by
/// `sign.sh`.
///
/// Both bundles exist for the same reason: macOS keys a privacy grant to a code
/// identity, and a bare Mach-O's identity is a hash of itself that every build
/// changes. The daemon's Accessibility grant is one; the grabber's Input Monitoring
/// grant is the other, which is also why it cannot be a bare binary - a root
/// LaunchDaemon cannot show the approval dialog, so the entry has to be addable by
/// hand from a bundle. `bin/kxdesk` and `bin/kxdesk-grabber` stay plain executables
/// for the command line, where no identity is wanted.
fn app(
    b: *std.Build,
    name: []const u8,
    exe: *std.Build.Step.Compile,
    info: std.Build.LazyPath,
    icon: ?std.Build.LazyPath,
) void {
    // The install prefix rather than the build root: what a build stages in the
    // prefix is what `brew` copies out of it. The inner binary is a copy, not a
    // link, because a signature covers the file.
    const directory = b.graph.path(.install_prefix, b.fmt("{s}.app", .{name}));
    const contents = directory.path(b, "Contents");
    const macos = contents.path(b, "MacOS");

    const stage = b.addSystemCommand(&.{"mkdir"});
    stage.addArg("-p");
    stage.addFileArg(macos);

    const copy = b.addSystemCommand(&.{"cp"});
    copy.addFileArg(exe.getEmittedBin());
    copy.addFileArg(macos.path(b, exe.name));
    copy.step.dependOn(&stage.step);

    const install_info = b.addSystemCommand(&.{"cp"});
    install_info.addFileArg(info);
    install_info.addFileArg(contents.path(b, "Info.plist"));
    install_info.step.dependOn(&copy.step);

    var last: *std.Build.Step = &install_info.step;
    if (icon) |file| {
        const resources = b.addSystemCommand(&.{"mkdir"});
        resources.addArg("-p");
        resources.addFileArg(contents.path(b, "Resources"));
        resources.step.dependOn(&install_info.step);

        const install_icon = b.addSystemCommand(&.{"cp"});
        install_icon.addFileArg(file);
        install_icon.addFileArg(contents.path(b, "Resources").path(b, b.fmt("{s}.icns", .{name})));
        install_icon.step.dependOn(&resources.step);
        last = &install_icon.step;
    }

    // `sign.sh`, not `codesign -` here: an ad-hoc signature's identity is the
    // binary's cdhash, so every build would be a different application as far as
    // macOS is concerned and the grants would not carry over. The script reads the
    // identifier from the plist, creates a self-signed certificate on first use, and
    // signs every build with that.
    const sign = b.addSystemCommand(&.{"bash"});
    sign.addFileArg(b.path("sign.sh"));
    sign.addFileArg(directory);
    sign.step.dependOn(last);

    b.getInstallStep().dependOn(&sign.step);
}

/// The version build.zig.zon declares.
///
/// Everything the manifest carries that is not the version is ignored, so that
/// the manifest can grow fields without this having to know them.
fn manifestVersion(b: *std.Build) []const u8 {
    const Manifest = struct { version: []const u8 };

    const path = b.root.joinStringZ(b.allocator, "build.zig.zon") catch
        @panic("build.zig.zon path could not be resolved");
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        b.graph.io,
        path,
        b.allocator,
        .unlimited,
        .of(u8),
        0,
    ) catch @panic("build.zig.zon could not be read");

    var arena_state: std.heap.ArenaAllocator = .init(b.allocator);
    defer arena_state.deinit();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const manifest = std.zon.parse.fromSlice(Manifest, .{
        .gpa = b.allocator,
        .arena = arena_state.allocator(),
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch @panic("build.zig.zon does not declare a version");

    return b.allocator.dupe(u8, manifest.version) catch @panic("out of memory");
}
