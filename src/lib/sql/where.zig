const std = @import("std");

const meta = @import("../meta.zig");
const escape = @import("escape.zig");
const parameterized_snippet = @import("parameterized_snippet.zig");

pub fn Where(comptime Expression: type) type {
    return struct {
        pub const Params = Expression.Params;

        expression: Expression,

        pub fn params(self: *const @This()) Params {
            return self.expression.params;
        }

        pub fn writeToSql(writer: *std.Io.Writer, next_placeholder: *usize) std.Io.Writer.Error!void {
            try Expression.writeToSql(writer, next_placeholder);
        }
    };
}

fn writeExpressionFromParams(writer: *std.Io.Writer, comptime Params: type) std.Io.Writer.Error!void {
    var requires_leading_and = false;
    for (@typeInfo(Params).@"struct".fields) |field| {
        if (requires_leading_and) {
            try writer.writeAll(" AND ");
        }
        try escape.writeEscapedIdentifier(writer, field.name);
        try writer.writeAll(" = ?");
        requires_leading_and = true;
    }
}

fn expressionFromParamsCount(comptime Params: type) usize {
    var discarding_writer = std.Io.Writer.Discarding.init(&.{});
    writeExpressionFromParams(&discarding_writer.writer, Params) catch unreachable;
    return discarding_writer.fullCount();
}

fn comptimeExpressionFromParams(comptime Params: type) *const [expressionFromParamsCount(Params):0]u8 {
    comptime {
        var buf: [expressionFromParamsCount(Params):0]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        writeExpressionFromParams(&writer, Params) catch unreachable;
        buf[buf.len] = 0;

        const final = buf;
        return &final;
    }
}

pub fn FromParams(comptime Params: type) type {
    return Where(parameterized_snippet.ParameterizedSnippet(
        comptimeExpressionFromParams(Params),
        meta.TupleFromStruct(Params),
    ));
}

pub fn fromParams(params: anytype) FromParams(@TypeOf(params)) {
    return .{ .expression = .{ .params = meta.structToTuple(params) } };
}
