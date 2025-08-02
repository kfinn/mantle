const std = @import("std");

pub fn escapedFieldCount(field: []const u8) usize {
    var count = 2;
    for (field) |c| {
        if (c == '"') {
            count += 2;
        } else {
            count += 1;
        }
    }
    return count;
}

pub fn writeEscapedField(writer: anytype, field: []const u8) @TypeOf(writer).Error!void {
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

pub fn bufEscapeField(buf: []u8, field: []const u8) std.fmt.BufPrintError![]u8 {
    var buf_stream = std.io.fixedBufferStream(buf);
    var buf_writer = buf_stream.writer();
    var bytes_written: usize = 0;
    try buf_writer.writeByte('"');
    bytes_written += 1;
    for (field) |c| {
        if (c == '"') {
            try buf_writer.writeAll("\\\"");
            bytes_written += 2;
        } else {
            try buf_writer.writeByte(c);
            bytes_written += 1;
        }
    }
    try buf_writer.writeByte('"');
    bytes_written += 1;

    return buf[0..bytes_written];
}
