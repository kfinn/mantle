const std = @import("std");

pub fn escapedIdentifierCount(field: []const u8) usize {
    const counting_writer = std.io.countingWriter(std.io.null_writer);
    writeEscapedIdentifier(counting_writer, field) catch unreachable;
    return counting_writer.bytes_written;
}

pub fn writeEscapedIdentifier(writer: *std.Io.Writer, field: []const u8) std.Io.Writer.Error!void {
    try writer.writeByte('"');
    for (field) |c| {
        if (c == '"') {
            try writer.writeAll("\"\"");
        } else {
            try writer.writeByte(c);
        }
    }
    try writer.writeByte('"');
}
