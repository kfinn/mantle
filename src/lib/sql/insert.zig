const std = @import("std");

const meta = @import("../meta.zig");
const escape = @import("escape.zig");
const parameterized_snippet = @import("parameterized_snippet.zig");

pub const Into = struct {
    table_name: []const u8,
    alias: ?[]const u8,

    pub fn table(table_name: []const u8) @This() {
        return .{
            .table_name = table_name,
            .alias = null,
        };
    }

    pub fn writeToSql(self: *const @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeByte(' ');
        try escape.writeEscapedIdentifier(writer, self.table_name);
        if (self.alias) |alias| {
            try writer.writeAll(" AS ");
            try escape.writeEscapedIdentifier(writer, alias);
        }
    }
};

pub fn Insert(comptime opts: struct {
    into: Into,
    ChangeSet: type,
    Returning: ?type = null,
}) type {
    @setEvalBranchQuota(100000);

    return struct {
        pub const into = opts.into;
        pub const ChangeSet = opts.ChangeSet;
        pub const Returning = opts.Returning orelse parameterized_snippet.Empty;
        pub const Params = meta.FlattenedTuples(struct {
            meta.TupleFromStruct(ChangeSet),
            Returning.Params,
        });

        change_set: ChangeSet,
        returning: Returning,

        pub fn writeToSql(writer: *std.Io.Writer, next_placeholder: *usize) std.Io.Writer.Error!void {
            try writer.writeAll("INSERT INTO");
            try into.writeToSql(writer);
            try writer.writeAll(" (");

            const change_set_fields = @typeInfo(ChangeSet).@"struct".fields;
            if (change_set_fields.len == 0) @compileError("Cannot create SQL INSERT, " ++ @typeName(ChangeSet) ++ " has no fields");
            {
                var requires_comma = false;
                for (change_set_fields) |field| {
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
                for (change_set_fields) |_| {
                    if (requires_comma) {
                        try writer.writeAll(", ");
                    }
                    try parameterized_snippet.writeToSqlWithPlaceholders(writer, "?", next_placeholder);
                    requires_comma = true;
                }
            }
            try writer.writeByte(')');
            if (Returning != parameterized_snippet.Empty) {
                try writer.writeAll(" RETURNING ");
                try Returning.writeToSql(writer, next_placeholder);
            }
        }

        pub fn params(self: *const @This()) Params {
            return meta.flattenTuples(.{
                meta.structToTuple(self.change_set),
                if (Returning != parameterized_snippet.Empty) self.returning.params() else parameterized_snippet.empty_params,
            });
        }
    };
}
