const std = @import("std");

expression: []const u8,
name: ?[]const u8,

pub fn fromColumn(column_name: []const u8) @This() {
    return .{ .expression = column_name, .name = null };
}

pub fn writeToSql(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
    if (self.name) |name| {
        try writer.print("({s}) AS {s}", .{ self.expression, name });
    }
    try writer.print("{s}", .{self.expression});
}
