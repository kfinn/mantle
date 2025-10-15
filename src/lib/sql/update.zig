const std = @import("std");

const meta = @import("../meta.zig");
const escape = @import("escape.zig");
const Into = @import("Into.zig");
const Output = @import("Output.zig");

pub fn Update(
    comptime into_param: Into,
    comptime ChangeSetParam: type,
    comptime WhereParam: type,
    comptime returning_param: []const Output,
) type {
    @setEvalBranchQuota(10000);

    return struct {
        pub const into = into_param;
        pub const ChangeSet = ChangeSetParam;
        pub const Where = WhereParam;
        pub const returning = returning_param;

        change_set: ChangeSet,
        where: Where,

        fn writeToSql(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            var next_placeholder: usize = 1;
            try writer.writeAll("UPDATE ");
            try into.writeToSql(writer);
            try writer.writeAll("SET ");
            const change_set_fields = @typeInfo(ChangeSet).@"struct".fields;
            {
                var requires_comma = false;
                for (change_set_fields) |field| {
                    if (requires_comma) {
                        try writer.writeAll(", ");
                    }
                    try escape.writeEscapedIdentifier(writer, field.name);
                    try writer.print(" = ${d}", .{next_placeholder});
                    next_placeholder += 1;
                    requires_comma = true;
                }
            }
            try writer.writeAll(" WHERE ");
            try Where.writeToSql(writer, &next_placeholder);
            try writer.writeAll("RETURNING ");
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
            @setEvalBranchQuota(10000);

            var discarding_writer = std.Io.Writer.Discarding.init(&.{});
            writeToSql(&discarding_writer.writer) catch unreachable;
            return discarding_writer.fullCount();
        }

        pub fn toSql() *const [comptimeToSqlCount():0]u8 {
            @setEvalBranchQuota(10000);

            const sql: [comptimeToSqlCount():0]u8 = comptime sql: {
                var buf: [comptimeToSqlCount():0]u8 = undefined;
                var fixed_buffer_writer = std.Io.Writer.fixed(&buf);
                writeToSql(&fixed_buffer_writer) catch unreachable;
                buf[buf.len] = 0;
                break :sql buf;
            };
            return &sql;
        }

        pub fn params(self: *const @This()) meta.MergedTuples(meta.TupleFromStruct(ChangeSet), Where.Params) {
            return meta.mergeTuples(
                meta.structToTuple(self.change_set),
                self.where.params,
            );
        }
    };
}
