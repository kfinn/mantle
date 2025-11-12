const std = @import("std");

const escape = @import("escape.zig");
const parameterized_snippet = @import("parameterized_snippet.zig");

pub fn From(comptime opts: struct { Expression: type, name: ?[]const u8 = null }) type {
    return struct {
        pub const Expression = opts.Expression;
        pub const Params = Expression.Params;

        expression: Expression,

        pub fn params(self: *const @This()) Params {
            return self.expression.params;
        }

        pub fn writeToSql(writer: *std.Io.Writer, next_placeholder: *usize) std.Io.Writer.Error!void {
            if (opts.name) |_| {
                try writer.writeByte('(');
            }
            try Expression.writeToSql(writer, next_placeholder);
            if (opts.name) |name| {
                try writer.writeAll(") ");
                try escape.writeEscapedIdentifier(writer, name);
            }
        }
    };
}

pub fn Table(comptime name: []const u8) type {
    return From(.{ .Expression = parameterized_snippet.ParameterizedSnippet(name, parameterized_snippet.EmptyParams) });
}
