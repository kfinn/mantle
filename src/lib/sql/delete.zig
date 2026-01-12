const std = @import("std");

const meta = @import("../meta.zig");
const parameterized_snippet = @import("parameterized_snippet.zig");

pub fn Delete(comptime opts: struct {
    From: type,
    Where: ?type = null,
}) type {
    @setEvalBranchQuota(100000);

    return struct {
        pub const From = opts.From;
        pub const Where = opts.Where orelse parameterized_snippet.Empty;
        pub const Returning = opts.Returning orelse parameterized_snippet.Empty;
        pub const Params = meta.FlattenedTuples(struct {
            From.Params,
            Where.Params,
        });

        from: From,
        where: Where,

        pub fn writeToSql(writer: *std.Io.Writer, next_placeholder: *usize) std.Io.Writer.Error!void {
            try writer.writeAll("DELETE FROM ");
            std.debug.assert(From != parameterized_snippet.Empty);
            try From.writeToSql(writer, next_placeholder);

            if (Where != parameterized_snippet.Empty) {
                try writer.writeAll(" WHERE ");
                try Where.writeToSql(writer, next_placeholder);
            }
        }

        pub fn params(self: *const @This()) Params {
            return meta.flattenTuples(.{
                self.from.params(),
                if (Where != parameterized_snippet.Empty) self.where.params() else parameterized_snippet.empty_params,
            });
        }
    };
}
