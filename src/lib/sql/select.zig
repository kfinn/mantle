const std = @import("std");

const meta = @import("../meta.zig");
const escape = @import("escape.zig");
const Output = @import("Output.zig");
const where = @import("where.zig");

pub const From = struct {
    expression: []const u8,
    name: ?[]const u8 = null,

    pub fn fromTable(table_name: []const u8) @This() {
        return .{ .expression = table_name };
    }

    pub fn writeToSql(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
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
    comptime opts: struct {
        has_limit: bool = false,
        has_offset: bool = false,
    },
) type {
    @setEvalBranchQuota(10000);

    return struct {
        pub const outputs = outputs_param;
        pub const from = from_param;
        pub const Where = WhereParam;
        pub const has_limit = opts.has_limit;
        pub const has_offset = opts.has_offset;
        pub const Params = params: {
            const where_param_fields = @typeInfo(WhereParam.Params).@"struct".fields;
            var types: [where_param_fields.len + (if (opts.has_limit) 1 else 0) + (if (opts.has_offset) 1 else 0)]type = undefined;
            for (where_param_fields, 0..) |where_param_field, index| {
                types[index] = where_param_field.type;
            }
            var next_field_index = where_param_fields.len;
            if (opts.has_limit) {
                types[next_field_index] = usize;
                next_field_index += 1;
            }
            if (opts.has_offset) {
                types[next_field_index] = usize;
                next_field_index += 1;
            }
            break :params std.meta.Tuple(&types);
        };

        where: Where,
        limit: if (has_limit) usize else void,
        offset: if (has_offset) usize else void,

        pub fn merge(self: *const @This(), rhs: anytype, comptime operator: []const u8) Merged(@This(), @TypeOf(rhs), operator) {
            var limit: ?usize = self.limit;
            if (rhs.limit) |rhs_limit| {
                if (limit) |self_limit| {
                    limit = @min(self_limit, rhs_limit);
                } else {
                    limit = rhs_limit;
                }
            }
            var offset: ?usize = self.offset;
            if (rhs.offset) |rhs_offset| {
                if (offset) |self_offset| {
                    offset = @min(self_offset, rhs_offset);
                } else {
                    offset = rhs_offset;
                }
            }

            return .{
                .outputs = self.outputs,
                .from = self.from,
                .where = self.where.merge(rhs.where),
                .limit = limit,
                .offset = offset,
            };
        }

        fn writeToSql(writer: *std.Io.Writer) std.Io.Writer.Error!void {
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
            if (has_offset) {
                try writer.print(" OFFSET ${d}", .{next_placeholder});
                next_placeholder += 1;
            }
        }

        fn comptimeToSqlCount() usize {
            @setEvalBranchQuota(10000);

            var discarding_writer: std.Io.Writer.Discarding = .init(&.{});
            writeToSql(&discarding_writer.writer) catch unreachable;
            return discarding_writer.fullCount();
        }

        pub fn toSql() *const [comptimeToSqlCount():0]u8 {
            @setEvalBranchQuota(10000);

            const sql: [comptimeToSqlCount():0]u8 = comptime sql: {
                var buf: [comptimeToSqlCount():0]u8 = undefined;
                var writer = std.Io.Writer.fixed(&buf);
                writeToSql(&writer) catch unreachable;
                buf[buf.len] = 0;
                break :sql buf;
            };
            return &sql;
        }

        pub fn params(self: *const @This()) Params {
            if (has_limit and has_offset) {
                return meta.mergeTuples(self.where.params, .{ self.limit, self.offset });
            }
            if (has_limit) {
                return meta.mergeTuples(self.where.params, .{self.limit});
            }
            if (has_offset) {
                return meta.mergeTuples(self.where.params, .{self.offset});
            }
            return self.where.params;
        }
    };
}
