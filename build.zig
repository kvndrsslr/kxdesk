const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // kxdesk sits on the bar's event path, so an optimized build is the default;
    // `-Doptimize=Debug` still works for debugging.
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseFast)",
    ) orelse .ReleaseFast;

    const exe = b.addExecutable(.{
        .name = "kxdesk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // `kxdesk version` reports the version the binary was built from, so it is
    // read out of the manifest here and injected as a build option: build.zig.zon
    // stays the one place it is written down.
    const options = b.addOptions();
    options.addOption([]const u8, "version", manifestVersion(b));
    exe.root_module.addOptions("build_options", options);

    // SQLite is bound through its C interface: the standard library has no
    // SQLite any more, so the SDK header is translated into a Zig module here
    // and linked against the copy macOS ships - which needs no dependency, and
    // is newer than the Homebrew one besides.
    const sqlite = b.addTranslateC(.{
        .root_source_file = b.path("vendor/sqlite.h"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("sqlite", sqlite.createModule());
    exe.root_module.linkSystemLibrary("sqlite3", .{});

    // The upstream SketchyBar header is compiled into the helper: it defines the
    // mach wire format as `static inline` functions, so `platform.m` including it
    // statically links it here.
    exe.root_module.addIncludePath(b.path("vendor"));
    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/platform.m"),
        .flags = &.{ "-fobjc-arc", "-Wall", "-Wextra", "-Wno-unused-parameter" },
    });
    exe.root_module.linkFramework("AppKit", .{});
    exe.root_module.linkFramework("CoreFoundation", .{});
    // CoreText locates the installed app font; the font itself describes the
    // application -> icon mapping that the helper reads at startup.
    exe.root_module.linkFramework("CoreText", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.linkFramework("IOKit", .{});

    b.installArtifact(exe);
}

/// The version build.zig.zon declares.
///
/// Everything the manifest carries that is not the version is ignored, so that
/// the manifest can grow fields without this having to know them.
fn manifestVersion(b: *std.Build) []const u8 {
    const Manifest = struct { version: []const u8 };

    const source = b.build_root.handle.readFileAllocOptions(
        b.graph.io,
        "build.zig.zon",
        b.allocator,
        .unlimited,
        .of(u8),
        0,
    ) catch @panic("build.zig.zon could not be read");

    const manifest = std.zon.parse.fromSliceAlloc(Manifest, b.allocator, source, null, .{
        .ignore_unknown_fields = true,
        .free_on_error = false,
    }) catch @panic("build.zig.zon does not declare a version");

    return manifest.version;
}
