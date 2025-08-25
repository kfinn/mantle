const std = @import("std");

const escape = @import("escape.zig");
const Output = @import("Output.zig");
const where = @import("where.zig");

pub const From = struct {
    expression: []const u8,
    name: ?[]const u8,

    pub fn fromTable(table_name: []const u8) @This() {
        return .{ .expression = table_name, .name = null };
    }

    pub fn writeToSql(self: *const @This(), writer: anytype) @TypeOf(writer).Error!void {
        try writer.writeAll("FROM ");
        if (self.name) |name| {
            try writer.print("({s}) ", .{self.expression});
            try escape.writeEscapedIdentifier(writer, name);
        }
        try writer.print("{s}", .{self.expression});
    }
};

fn Merged(comptime Lhs: type, comptime Rhs: type, comptime operator: []const u8) type {
    std.debug.assert(Lhs.outputs.len == Rhs.outputs.len);
    for (Lhs.outputs, Rhs.outputs) |lhs_output, rhs_output| {
        std.debug.assert(std.mem.eql(u8, lhs_output.expression, rhs_output.expression));
        std.debug.assert(std.mem.eql(u8, lhs_output.name, rhs_output.name));
    }
    std.debug.assert(std.mem.eql(u8, Lhs.from.expression, Rhs.from.expression));
    std.debug.assert(std.mem.eql(u8, Lhs.from.name, Rhs.from.name));

    return Select(
        Lhs.outputs,
        Lhs.from,
        where.Merged(Lhs.Where, Rhs.Where, operator),
        Lhs.limited || Rhs.limited,
    );
}

pub fn Select(
    comptime outputs_param: []const Output,
    comptime from_param: From,
    comptime WhereParam: type,
    comptime has_limit_param: bool,
) type {
    return struct {
        pub const outputs = outputs_param;
        pub const from = from_param;
        pub const Where = WhereParam;
        pub const has_limit = has_limit_param;
        pub const Params = params: {
            if (!has_limit_param) {
                break :params WhereParam.Params;
            }

            const where_param_fields = @typeInfo(WhereParam.Params).@"struct".fields;
            var types: [where_param_fields.len + 1]type = undefined;
            for (where_param_fields, 0..) |where_param_field, index| {
                types[index] = where_param_field.type;
            }
            types[where_param_fields.len] = usize;
            break :params std.meta.Tuple(&types);
        };

        where: Where,
        limit: if (has_limit) usize else void,

        pub fn merge(self: *const @This(), rhs: anytype, comptime operator: []const u8) Merged(@This(), @TypeOf(rhs), operator) {
            var limit: ?usize = self.limit;
            if (rhs.limit) |rhs_limit| {
                if (limit) |self_limit| {
                    limit = @min(self_limit, rhs_limit);
                } else {
                    limit = rhs_limit;
                }
            }

            return .{
                .outputs = self.outputs,
                .from = self.from,
                .where = self.where.merge(rhs.where),
                .limit = limit,
            };
        }

        fn writeToSql(writer: anytype) @TypeOf(writer).Error!void {
            var next_placeholder: usize = 1;
            try writer.writeAll("SELECT ");
            var requires_comma = false;
            for (outputs) |output| {
                if (requires_comma) {
                    try writer.writeAll(", ");
                }
                try output.writeToSql(writer);
                requires_comma = true;
            }
            try writer.writeByte(' ');
            try from.writeToSql(writer);
            try writer.writeAll(" WHERE ");
            try Where.writeToSql(writer, &next_placeholder);
            if (has_limit) {
                try writer.print(" LIMIT ${d}", .{next_placeholder});
                next_placeholder += 1;
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

        pub fn params(self: *const @This()) Params {
            if (!has_limit) {
                return self.where.params;
            }

            var result: Params = undefined;
            inline for (0..self.where.params.len) |index| {
                result[index] = self.where.params[index];
            }
            result[self.where.params.len] = self.limit;
            return result;
        }
    };
}
