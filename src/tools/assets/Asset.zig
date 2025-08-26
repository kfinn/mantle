const std = @import("std");

dir: std.fs.Dir,
path: [:0]const u8,

pub fn init(dir: std.fs.Dir, path: [:0]const u8) @This() {
    return .{
        .dir = dir,
        .path = path,
    };
}

pub fn deinit(self: *@This()) void {
    self.* = undefined;
}

pub fn pathWithDigest(self: *const @This(), allocator: std.mem.Allocator) ![]u8 {
    const opt_dirname = std.fs.path.dirname(self.path);
    const stem = std.fs.path.stem(self.path);
    const extension = std.fs.path.extension(self.path);

    if (opt_dirname) |dirname| {
        return try std.fmt.allocPrint(
            allocator,
            "{s}/{s}-{s}{s}",
            .{
                dirname,
                stem,
                try self.digest(),
                extension,
            },
        );
    } else {
        return try std.fmt.allocPrint(
            allocator,
            "{s}-{s}{s}",
            .{
                stem,
                try self.digest(),
                extension,
            },
        );
    }
}

fn digest(self: *const @This()) ![std.Build.Cache.Hasher.mac_length * 2]u8 {
    var hasher = std.Build.Cache.hasher_init;

    var file = try self.dir.openFileZ(self.path, .{});
    defer file.close();

    var buffer: [4 * 1024]u8 = undefined;
    while (true) {
        const bytes_read = try file.read(&buffer);
        if (bytes_read == 0) {
            break;
        }
        hasher.update(&buffer);
    }

    const raw_hash = hasher.finalResult();
    var hex_hash: [std.Build.Cache.Hasher.mac_length * 2]u8 = undefined;

    for (raw_hash, 0..) |byte, byte_index| {
        const buf = hex_hash[(2 * byte_index)..(2 * byte_index + 2)];
        _ = std.fmt.bufPrint(buf, "{x:0>2}", .{byte}) catch unreachable;
    }

    return hex_hash;
}

pub fn install(
    self: *const @This(),
    dest_dir: std.fs.Dir,
    dest_path: []const u8,
    digested_asset_paths_by_asset_path: *const std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
) !void {
    if (digested_asset_paths_by_asset_path.count() == 0) {
        try self.installWithoutTransforming(dest_dir, dest_path);
    }

    const extension = std.fs.path.extension(self.path);
    if (std.mem.eql(u8, ".css", extension)) {
        try self.installCss(
            dest_dir,
            dest_path,
            digested_asset_paths_by_asset_path,
            allocator,
        );
    } else {
        try self.installWithoutTransforming(dest_dir, dest_path);
    }
}

fn installWithoutTransforming(
    self: *const @This(),
    dest_dir: std.fs.Dir,
    dest_path: []const u8,
) !void {
    if (std.fs.path.dirname(dest_path)) |dest_dirname| {
        try dest_dir.makePath(dest_dirname);
    }
    try self.dir.copyFile(self.path, dest_dir, dest_path, .{});
}

fn installCss(
    self: *const @This(),
    dest_dir: std.fs.Dir,
    dest_path: []const u8,
    digested_asset_paths_by_asset_path: *const std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
) !void {
    var max_asset_path_len: usize = 0;
    var asset_paths_iterator = digested_asset_paths_by_asset_path.keyIterator();
    while (asset_paths_iterator.next()) |asset_path| {
        max_asset_path_len = @max(asset_path.len, max_asset_path_len);
    }

    var url_buf = try allocator.alloc(u8, max_asset_path_len);
    defer allocator.free(url_buf);
    var url_len: usize = 0;

    const State = enum {
        plain,
        u,
        ur,
        url,
        @"url(",
        eof,
    };

    var src_file = try self.dir.openFile(self.path, .{});
    defer src_file.close();

    var src_file_reader_buffer: [1024]u8 = undefined;
    var src_file_reader = src_file.reader(&src_file_reader_buffer);
    const reader = &src_file_reader.interface;

    if (std.fs.path.dirname(dest_path)) |dest_dirname| {
        try dest_dir.makePath(dest_dirname);
    }

    var dest_file = try dest_dir.createFile(dest_path, .{});
    defer dest_file.close();

    var dest_file_writer_buffer: [1024]u8 = undefined;
    var dest_file_writer = dest_file.writer(&dest_file_writer_buffer);
    const writer = &dest_file_writer.interface;

    state: switch (State.plain) {
        .plain => {
            const c = try readOptByte(reader) orelse continue :state .eof;
            try writer.writeByte(c);
            switch (c) {
                'u' => continue :state .u,
                else => continue :state .plain,
            }
        },
        .u => {
            const c = try readOptByte(reader) orelse continue :state .eof;
            try writer.writeByte(c);
            switch (c) {
                'r' => continue :state .ur,
                else => continue :state .plain,
            }
        },
        .ur => {
            const c = try readOptByte(reader) orelse continue :state .eof;
            try writer.writeByte(c);
            switch (c) {
                'l' => continue :state .url,
                else => continue :state .plain,
            }
        },
        .url => {
            const c = try readOptByte(reader) orelse continue :state .eof;
            try writer.writeByte(c);
            switch (c) {
                '(' => continue :state .@"url(",
                else => continue :state .plain,
            }
        },
        .@"url(" => {
            const c = try readOptByte(reader) orelse continue :state .eof;
            switch (c) {
                ')' => {
                    const url = url_buf[0..url_len];
                    if (digested_asset_paths_by_asset_path.get(url)) |digested_asset_path| {
                        try writer.writeAll(digested_asset_path);
                    } else {
                        try writer.writeAll(url);
                    }
                    try writer.writeByte(')');
                    url_len = 0;
                    continue :state .plain;
                },
                else => {
                    if (url_len < url_buf.len) {
                        url_buf[url_len] = c;
                        url_len += 1;
                        continue :state .@"url(";
                    } else {
                        try writer.writeAll(url_buf);
                        url_len = 0;
                        continue :state .plain;
                    }
                },
            }
        },
        .eof => {
            try writer.print("\n\n/*# sourceMappingURL={s} */\n", .{self.path});
        },
    }
}

fn readOptByte(reader: *std.Io.Reader) !?u8 {
    return reader.takeByte() catch |err| {
        switch (err) {
            error.EndOfStream => return null,
            else => return err,
        }
    };
}
