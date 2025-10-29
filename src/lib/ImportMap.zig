const std = @import("std");

writer: *std.Io.Writer,
requries_comma: bool = false,

pub const Entry = struct {
    specifier: []const u8,
    path: []const u8,

    pub fn init(specifier: []const u8, path: []const u8) @This() {
        return .{ .specifier = specifier, .path = path };
    }
};

pub fn init(writer: *std.Io.Writer) @This() {
    return .{ .writer = writer };
}

pub fn begin(self: *const @This()) !void {
    try self.writer.writeAll("<script type=\"importmap\">{ \"imports\":{");
}

pub fn end(self: *const @This()) !void {
    try self.writer.writeAll("}}</script>");
}

pub fn writeEntry(self: *@This(), entry: Entry) !void {
    if (self.requries_comma) {
        try self.writer.writeByte(',');
    }
    try self.writer.print("\"{s}\":\"{s}\"", .{ entry.specifier, entry.path });
    self.requries_comma = true;
}

pub fn writeEntries(self: *@This(), entries: []const Entry) !void {
    for (entries) |entry| {
        try self.writeEntry(entry);
    }
}
