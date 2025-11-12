const std = @import("std");

const meta = @import("../meta.zig");
const escape = @import("escape.zig");
const parameterized_snippet = @import("parameterized_snippet.zig");
const where = @import("where.zig");

const PresentLimit = struct {
    pub const Params = struct { i32 };
    pub const Expression = parameterized_snippet.ParameterizedSnippet("LIMIT ?", Params);

    expression: Expression,

    pub fn params(self: *const @This()) Params {
        return self.expression.params;
    }

    pub fn writeToSql(writer: *std.Io.Writer, next_placeholder: *usize) std.Io.Writer.Error!void {
        try Expression.writeToSql(writer, next_placeholder);
    }
};

const PresentOffset = struct {
    pub const Params = struct { i32 };
    pub const Expression = parameterized_snippet.ParameterizedSnippet("OFFSET ?", Params);

    expression: Expression,

    pub fn params(self: *const @This()) Params {
        return self.expression.params;
    }

    pub fn writeToSql(writer: *std.Io.Writer, next_placeholder: *usize) std.Io.Writer.Error!void {
        try Expression.writeToSql(writer, next_placeholder);
    }
};

pub fn Select(
    comptime opts: struct {
        OutputList: ?type = null,
        From: ?type = null,
        Where: ?type = null,
        has_limit: bool = false,
        has_offset: bool = false,
    },
) type {
    @setEvalBranchQuota(10000);

    return struct {
        pub const OutputList = opts.OutputList orelse parameterized_snippet.Empty;
        pub const From = opts.From orelse parameterized_snippet.Empty;
        pub const Where = opts.Where orelse parameterized_snippet.Empty;
        pub const Limit = if (opts.has_limit) PresentLimit else parameterized_snippet.Empty;
        pub const Offset = if (opts.has_offset) PresentOffset else parameterized_snippet.Empty;
        pub const Params = meta.FlattenedTuples(struct {
            OutputList.Params,
            From.Params,
            Where.Params,
            Limit.Params,
            Offset.Params,
        });

        output_list: OutputList,
        from: From,
        where: Where,
        limit: Limit,
        offset: Offset,

        fn writeToSql(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            var next_placeholder: usize = 1;
            try writer.writeAll("SELECT");
            if (OutputList == parameterized_snippet.Empty) {
                try writer.writeAll(" *");
            } else {
                try OutputList.writeToSql(writer, &next_placeholder);
            }

            std.debug.assert(From != parameterized_snippet.Empty);
            try writer.writeAll(" FROM ");
            try From.writeToSql(writer, &next_placeholder);

            if (Where != parameterized_snippet.Empty) {
                try writer.writeAll(" WHERE ");
                try Where.writeToSql(writer, &next_placeholder);
            }
            if (Limit != parameterized_snippet.Empty) {
                try writer.writeByte(' ');
                try Limit.writeToSql(writer, &next_placeholder);
            }
            if (Offset != parameterized_snippet.Empty) {
                try writer.writeByte(' ');
                try Offset.writeToSql(writer, &next_placeholder);
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
            return meta.flattenTuples(.{
                if (OutputList != parameterized_snippet.Empty) self.output_list.params() else parameterized_snippet.empty_params,
                if (From != parameterized_snippet.Empty) self.from.params() else parameterized_snippet.empty_params,
                if (Where != parameterized_snippet.Empty) self.where.params() else parameterized_snippet.empty_params,
                if (Limit != parameterized_snippet.Empty) self.limit.params() else parameterized_snippet.empty_params,
                if (Offset != parameterized_snippet.Empty) self.offset.params() else parameterized_snippet.empty_params,
            });
        }
    };
}
