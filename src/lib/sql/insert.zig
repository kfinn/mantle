const std = @import("std");

const meta = @import("../meta.zig");
const escape = @import("escape.zig");
const Output = @import("Output.zig");

pub fn Insert(
    comptime into_param: Into,
    comptime ValuesParam: type,
    comptime returning_param: []const Output,
) type {
    return struct {
        pub const into = into_param;
        pub const Values = ValuesParam;
        pub const returning = returning_param;

        values: Values,

        fn writeToSql(writer: anytype) @TypeOf(writer).Error!void {
            var next_placeholder: usize = 1;
            try writer.writeAll("INSERT");
            try into.writeToSql(writer);
            try writer.writeAll(" (");

            const values_fields = @typeInfo(Values).@"struct".fields;
            {
                var requires_comma = false;
                for (values_fields) |field| {
                    if (requires_comma) {
                        try writer.writeAll(", ");
                    }
                    try escape.writeEscapedIdentifier(writer, field.name);
                    requires_comma = true;
                }
            }
            try writer.writeAll(") VALUES (");
            {
                var requires_comma = false;
                for (values_fields) |_| {
                    if (requires_comma) {
                        try writer.writeAll(", ");
                    }
                    try writer.print("${d}", .{next_placeholder});
                    next_placeholder += 1;
                    requires_comma = true;
                }
            }
            try writer.writeAll(") RETURNING ");
            {
                var requires_comma = false;
                for (returning) |output| {
                    if (requires_comma) {
                        try writer.writeAll(", ");
                    }
                    try output.writeToSql(writer);
                    requires_comma = true;
                }
            }
        }

        fn comptimeToSqlCount() usize {
            var counting_writer = std.io.countingWriter(std.io.null_writer);
            writeToSql(counting_writer.writer()) catch unreachable;
            return counting_writer.bytes_written;
        }

        pub fn toSql() *const [comptimeToSqlCount():0]u8 {
            const sql: [comptimeToSqlCount():0]u8 = comptime sql: {
                var buf: [comptimeToSqlCount():0]u8 = undefined;
                var fixed_buffer_stream = std.io.fixedBufferStream(&buf);
                const writer = fixed_buffer_stream.writer();
                writeToSql(writer) catch unreachable;
                buf[buf.len] = 0;
                break :sql buf;
            };
            return &sql;
        }

        pub fn params(self: *const @This()) meta.TupleFromStruct(Values) {
            return meta.structToTuple(self.values);
        }
    };
}

const Into = struct {
    table_name: []const u8,
    alias: ?[]const u8,

    pub fn fromTable(table_name: []const u8) @This() {
        return .{
            .table_name = table_name,
            .alias = null,
        };
    }

    pub fn writeToSql(self: *const @This(), writer: anytype) @TypeOf(writer).Error!void {
        try writer.writeAll(" INTO");
        try escape.writeEscapedIdentifier(writer, self.table_name);
        if (self.alias) |alias| {
            try writer.print(" {s}", .{alias});
        }
    }
};
