const std = @import("std");

const escape = @import("escape.zig");

table_name: []const u8,
alias: ?[]const u8,

pub fn fromTable(table_name: []const u8) @This() {
    return .{
        .table_name = table_name,
        .alias = null,
    };
}

pub fn writeToSql(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try escape.writeEscapedIdentifier(writer, self.table_name);
    if (self.alias) |alias| {
        try writer.print(" {s}", .{alias});
    }
    try writer.writeByte(' ');
}
