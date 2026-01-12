const std = @import("std");

const pg = @import("pg");

const Repo = @import("Repo.zig");

uuids: []const []const u8,

pub fn castToDb(self: *const @This(), repo: *const Repo) !pg.Binary {
    const buffer = try repo.allocator.alloc(u8, 20 + 20 * self.uuids.len);
    var writer: std.Io.Writer = .fixed(buffer);

    writer.writeInt(i32, 1, .big) catch unreachable; // dimensions
    writer.writeInt(i32, 0, .big) catch unreachable; // bitmask of null
    writer.writeInt(i32, 2950, .big) catch unreachable; // oid for UUID
    writer.writeInt(i32, @intCast(self.uuids.len), .big) catch unreachable; // number of UUIDs
    writer.writeInt(i32, 1, .big) catch unreachable; // lower bound of this dimension

    for (self.uuids) |uuid| {
        writer.writeInt(i32, 16, .big) catch unreachable;
        writer.writeAll(uuid) catch unreachable;
    }

    return .{ .data = buffer };
}

pub fn format(
    self: @This(),
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.writeByte('[');
    var needs_comma = false;
    for (self.uuids) |uuid| {
        if (needs_comma) try writer.writeAll(", ");
        try writer.writeAll(uuid);
        needs_comma = true;
    }
    try writer.writeByte(']');
}
