const std = @import("std");

const meta = @import("../meta.zig");
const escape = @import("escape.zig");
const parameterized_snippet = @import("parameterized_snippet.zig");

pub const Table = struct {
    table_name: []const u8,
    alias: ?[]const u8,

    pub fn table(table_name: []const u8) @This() {
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
    }
};

pub fn Update(comptime opts: struct {
    into: Table,
    ChangeSet: type,
    Where: ?type = null,
    Returning: ?type = null,
}) type {
    @setEvalBranchQuota(100000);

    return struct {
        pub const into = opts.into;
        pub const ChangeSet = opts.ChangeSet;
        pub const Where = opts.Where orelse parameterized_snippet.Empty;
        pub const Returning = opts.Returning orelse parameterized_snippet.Empty;
        pub const Params = meta.FlattenedTuples(struct {
            meta.TupleFromStruct(ChangeSet),
            Where.Params,
            Returning.Params,
        });

        change_set: ChangeSet,
        where: Where,
        returning: Returning,

        pub fn writeToSql(writer: *std.Io.Writer, next_placeholder: *usize) std.Io.Writer.Error!void {
            try writer.writeAll("UPDATE ");
            try into.writeToSql(writer);
            try writer.writeAll(" SET ");
            const change_set_fields = @typeInfo(ChangeSet).@"struct".fields;
            if (change_set_fields.len == 0) @compileError("Cannot create SQL UPDATE, " ++ @typeName(ChangeSet) ++ " has no updated fields");
            {
                var requires_comma = false;
                for (change_set_fields) |field| {
                    if (requires_comma) {
                        try writer.writeAll(", ");
                    }
                    try escape.writeEscapedIdentifier(writer, field.name);
                    try parameterized_snippet.writeToSqlWithPlaceholders(writer, " = ?", next_placeholder);
                    requires_comma = true;
                }
            }
            if (Where != parameterized_snippet.Empty) {
                try writer.writeAll(" WHERE ");
                try Where.writeToSql(writer, next_placeholder);
            }
            if (Returning != parameterized_snippet.Empty) {
                try writer.writeAll(" RETURNING ");
                try Returning.writeToSql(writer, next_placeholder);
            }
        }

        pub fn params(self: *const @This()) Params {
            return meta.flattenTuples(.{
                meta.structToTuple(self.change_set),
                if (Where != parameterized_snippet.Empty) self.where.params() else parameterized_snippet.empty_params,
                if (Returning != parameterized_snippet.Empty) self.returning.params() else parameterized_snippet.empty_params,
            });
        }
    };
}
