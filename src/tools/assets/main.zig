const std = @import("std");

const Asset = @import("Asset.zig");
const Walker = @import("Walker.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    std.debug.assert(args.skip());
    const command = args.next() orelse fatal("Requires a command. Expected list or generate.", .{});
    if (std.mem.eql(u8, command, "list")) {
        try list(allocator, &args);
    } else if (std.mem.eql(u8, command, "generate")) {
        try generate(allocator, &args);
    } else {
        fatal("Unkonwn command: {s}. Expected list or generate.\n", .{command});
    }

    return std.process.cleanExit();
}

fn list(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const output_file_path = args.next() orelse fatal("Missing output file argument.", .{});
    const assets_path = args.next() orelse fatal("Missing assets argument.", .{});

    const output_file = try std.fs.cwd().createFile(output_file_path, .{});
    defer output_file.close();

    var output_file_buffer: [1024]u8 = undefined;
    var output_file_writer = output_file.writer(&output_file_buffer);
    const output_writer = &output_file_writer.interface;

    var walker = try Walker.init(allocator, assets_path);
    defer walker.deinit();

    while (try walker.next()) |asset| {
        try output_writer.print("{s}\n", .{asset.path});
    }
    try output_writer.flush();
}

fn generate(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const output_zig_path = args.next() orelse fatal("Missing output directory argument.", .{});
    const output_dir_path = args.next() orelse fatal("Missing output directory argument.", .{});
    const assets_path = args.next() orelse fatal("Missing assets argument.", .{});
    const dependencies_file_path = args.next() orelse fatal("Missing dependencies argument", .{});

    var digested_asset_paths_by_asset_path = std.StringHashMap([]const u8).init(allocator);
    defer {
        var iterator = digested_asset_paths_by_asset_path.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        digested_asset_paths_by_asset_path.deinit();
    }

    {
        var walker = try Walker.init(allocator, assets_path);
        defer walker.deinit();

        while (try walker.next()) |asset| {
            try digested_asset_paths_by_asset_path.put(
                try allocator.dupe(u8, asset.path),
                try asset.pathWithDigest(allocator),
            );
        }
    }

    var output_dir = try std.fs.cwd().openDir(output_dir_path, .{});
    defer output_dir.close();

    var dependencies_file = try std.fs.cwd().createFile(dependencies_file_path, .{});
    defer dependencies_file.close();

    var dependencies_file_buffer: [1024]u8 = undefined;
    var dependencies_file_writer = dependencies_file.writer(&dependencies_file_buffer);
    const dependencies_writer = &dependencies_file_writer.interface;

    try dependencies_writer.writeAll("assets:");

    var output_file = try std.fs.cwd().createFile(output_zig_path, .{});
    defer output_file.close();

    var output_file_buffer: [1024]u8 = undefined;
    var output_file_writer = output_file.writer(&output_file_buffer);
    const output_writer = &output_file_writer.interface;

    var digested_asset_paths_by_asset_path_iterator = digested_asset_paths_by_asset_path.iterator();
    try output_writer.writeAll("const std = @import(\"std\");\n");
    try output_writer.writeAll("pub const All = std.StaticStringMap(void).initComptime(.{\n");
    while (digested_asset_paths_by_asset_path_iterator.next()) |entry| {
        try output_writer.writeAll("    .{ \"/assets/");
        try writeEscapedPath(output_writer, entry.value_ptr.*);
        try output_writer.writeAll("\", .{} },\n");
    }
    try output_writer.writeAll("});\n");

    {
        var walker = try Walker.init(allocator, assets_path);
        defer walker.deinit();

        while (try walker.next()) |asset| {
            const path_with_digest = digested_asset_paths_by_asset_path.get(asset.path).?;
            try asset.install(
                output_dir,
                path_with_digest,
                &digested_asset_paths_by_asset_path,
            );

            try dependencies_writer.writeByte(' ');
            try writeEscapedPath(dependencies_writer, assets_path);
            try dependencies_writer.writeByte('/');
            try writeEscapedPath(dependencies_writer, asset.path);

            try output_writer.writeAll("pub const @\"");
            try writeEscapedPath(output_writer, asset.path);
            try output_writer.writeAll("\" = \"/assets/");
            try writeEscapedPath(output_writer, path_with_digest);
            try output_writer.writeAll("\";\n");
        }
    }

    try output_writer.flush();
    try dependencies_writer.flush();
}

fn writeEscapedPath(writer: *std.Io.Writer, path: []const u8) std.Io.Writer.Error!void {
    for (path) |c| {
        switch (c) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            else => try writer.writeByte(c),
        }
    }
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}
