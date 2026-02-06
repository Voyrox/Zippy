const std = @import("std");

const commands = @import("commands.zig");
const settings_mod = @import("settings.zig");
const generate = @import("generate.zig");

const Colors = commands.Colors;
const projectName = "[HaskMate]";

fn outWriteAll(s: []const u8) !void {
    try std.fs.File.stdout().writeAll(s);
}

fn outPrint(comptime fmt: []const u8, args: anytype) !void {
    const alloc = std.heap.page_allocator;
    const s = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(s);
    try std.fs.File.stdout().writeAll(s);
}

fn getLastModifiedNs(path: []const u8) !i128 {
    const st = std.fs.cwd().statFile(path) catch |err| switch (err) {
        error.FileNotFound => return std.time.nanoTimestamp(),
        else => return err,
    };
    return st.mtime;
}

fn spawnShell(alloc: std.mem.Allocator, cmd: []const u8) !std.process.Child {
    var child = std.process.Child.init(&[_][]const u8{ "sh", "-c", cmd }, alloc);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    return child;
}

fn runScriptOrCmd(
    alloc: std.mem.Allocator,
    maybe_settings: ?*const settings_mod.Settings,
    fullPath: []const u8,
) !std.process.Child {
    const rootPath = std.fs.path.dirname(fullPath) orelse ".";

    if (maybe_settings) |s| {
        if (s.cmd.len != 0) {
            return try spawnShell(alloc, s.cmd);
        }

        if (std.mem.eql(u8, s.script, "ghc")) {
            const cmd = try std.fmt.allocPrint(alloc, "stack ghc -- {s}", .{fullPath});
            defer alloc.free(cmd);
            return try spawnShell(alloc, cmd);
        } else if (std.mem.eql(u8, s.script, "stack")) {
            const cmd = try std.fmt.allocPrint(alloc, "stack build && stack run {s}", .{rootPath});
            defer alloc.free(cmd);
            return try spawnShell(alloc, cmd);
        } else if (std.mem.eql(u8, s.script, "cabal")) {
            const cmd = try std.fmt.allocPrint(alloc, "cabal build && cabal run {s}", .{rootPath});
            defer alloc.free(cmd);
            return try spawnShell(alloc, cmd);
        } else if (s.script.len != 0) {
            return try spawnShell(alloc, s.script);
        }
    }

    const cmd = try std.fmt.allocPrint(alloc, "stack ghc -- {s}", .{fullPath});
    defer alloc.free(cmd);
    return try spawnShell(alloc, cmd);
}

fn killChild(child: *std.process.Child) void {
    _ = child.kill() catch {};
    _ = child.wait() catch {};
}

fn monitorScript(
    alloc: std.mem.Allocator,
    delay_us: u64,
    fullPath: []const u8,
    initial_mtime: i128,
    maybe_settings: ?*const settings_mod.Settings,
    child_opt: *?std.process.Child,
) !void {
    _ = alloc;

    var last = initial_mtime;

    while (true) {
        std.Thread.sleep(delay_us * std.time.ns_per_us);

        const current = try getLastModifiedNs(fullPath);
        if (current > last) {
            try outPrint("{s}{s}{s} Detected file modification. Rebuilding and running...\n", .{
                Colors.yellow, projectName, Colors.white,
            });

            if (child_opt.*) |*child| {
                killChild(child);
                child_opt.* = null;
            }

            const new_child = try runScriptOrCmd(std.heap.page_allocator, maybe_settings, fullPath);
            child_opt.* = new_child;

            last = current;
        }
    }
}

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const alloc = gpa_state.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len == 1) {
        try outWriteAll("Please provide a file to monitor as an argument.\nExample: HaskMate app/Main.hs\n");
        return;
    }

    const arg1 = args[1];

    if (std.mem.eql(u8, arg1, "--help") or std.mem.eql(u8, arg1, "--h")) {
        try commands.displayHelpData(alloc);
        return;
    }
    if (std.mem.eql(u8, arg1, "--generate") or std.mem.eql(u8, arg1, "--gen")) {
        try generate.generateConfig();
        return;
    }
    if (std.mem.eql(u8, arg1, "--version") or std.mem.eql(u8, arg1, "--v")) {
        try commands.displayVersionData();
        return;
    }
    if (std.mem.eql(u8, arg1, "--commands")) {
        try commands.displayCommands();
        return;
    }
    if (std.mem.eql(u8, arg1, "--config")) {
        try commands.displayConfigData();
        return;
    }
    if (std.mem.eql(u8, arg1, "--log")) {
        try commands.displayLogData();
        return;
    }
    if (std.mem.eql(u8, arg1, "--clear")) {
        try commands.displayClearData();
        return;
    }
    if (std.mem.eql(u8, arg1, "--credits")) {
        try commands.displayCreditsData();
        return;
    }

    const jsonPath = "HaskMate.json";

    var loaded: ?settings_mod.Settings = null;
    var loaded_ptr: ?*settings_mod.Settings = null;

    const maybe_s = try settings_mod.loadSettings(alloc, jsonPath);
    if (maybe_s) |s| {
        loaded = s;
        loaded_ptr = &loaded.?;
        try outPrint("{s}{s}{s} Loaded settings from HaskMate.json\n", .{
            Colors.green, projectName, Colors.white,
        });
    } else {
        try outPrint("{s}{s}{s} No HaskMate.json file found. Using default settings.\n", .{
            Colors.yellow, projectName, Colors.white,
        });
    }
    defer if (loaded_ptr) |p| settings_mod.freeSettings(alloc, p);

    const delay_us: u64 = if (loaded_ptr) |p| (p.delay orelse 1_000_000) else 1_000_000;

    const cwd = try std.fs.cwd().realpathAlloc(alloc, ".");
    defer alloc.free(cwd);

    const fullPath = try std.fs.path.join(alloc, &[_][]const u8{ cwd, arg1 });
    defer alloc.free(fullPath);

    try outPrint("{s}{s}{s} Starting HaskMate v1.3.0...\n", .{ Colors.green, projectName, Colors.white });
    try outPrint("{s}{s}{s} Running script path: {s}\n", .{ Colors.green, projectName, Colors.white, fullPath });
    try outPrint("{s}{s}{s} Watching for file modifications. Press {s}Ctrl+C{s} to exit.\n", .{
        Colors.green, projectName, Colors.white, Colors.red, Colors.white,
    });

    var child: ?std.process.Child = null;
    defer if (child) |*c| killChild(c);

    const spawned = try runScriptOrCmd(alloc, loaded_ptr, fullPath);
    child = spawned;

    const lastModified = try getLastModifiedNs(fullPath);
    try monitorScript(alloc, delay_us, fullPath, lastModified, loaded_ptr, &child);
}
