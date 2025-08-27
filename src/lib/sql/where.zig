const std = @import("std");

const meta = @import("../meta.zig");
const sql_escape = @import("escape.zig");

pub fn Where(comptime expression_param: []const u8, comptime ParamsParam: type) type {
    return struct {
        pub const expression = expression_param;
        pub const Params = ParamsParam;

        params: Params,

        pub fn merge(self: *const @This(), rhs: anytype, comptime operator: []const u8) Merged(@This(), @TypeOf(rhs), operator) {
            return .{ .params = meta.mergeTuples(self.params, rhs.params) };
        }

        pub fn writeToSql(writer: *std.Io.Writer, next_placeholder: *usize) std.Io.Writer.Error!void {
            const State = enum {
                init,
                literal_value,
                literal_value_escape,
                identifier,
                question_mark,
            };
            var state: State = .init;
            expression: for (expression) |c| {
                switch (state) {
                    .init => {
                        if (c == '?') {
                            state = .question_mark;
                            continue :expression;
                        }
                        try writer.writeByte(c);
                        if (c == '\'') {
                            state = .literal_value;
                        } else if (!std.ascii.isWhitespace(c)) {
                            state = .identifier;
                        }
                    },
                    .literal_value => {
                        try writer.writeByte(c);
                        if (c == '\'') {
                            state = .init;
                        } else if (c == '\\') {
                            state = .literal_value_escape;
                        }
                    },
                    .literal_value_escape => {
                        try writer.writeByte(c);
                        state = .literal_value;
                    },
                    .identifier => {
                        try writer.writeByte(c);
                        if (std.ascii.isWhitespace(c)) {
                            state = .init;
                        }
                    },
                    .question_mark => {
                        if (std.ascii.isWhitespace(c)) {
                            try writer.print("${d}{c}", .{ next_placeholder.*, c });
                            next_placeholder.* += 1;
                            state = .init;
                        } else {
                            try writer.print{ "?{c}", .{c} };
                            state = .identifier;
                        }
                    },
                }
            }
            if (state == .question_mark) {
                try writer.print("${d}", .{next_placeholder.*});
                next_placeholder.* += 1;
            }
            try writer.writeByte(' ');
        }
    };
}

pub fn fromExpression(comptime expression: []const u8, params: anytype) Where(expression, @TypeOf(params)) {
    return .{ .params = params };
}

fn writeExpressionFromParams(writer: *std.Io.Writer, comptime Params: type) std.Io.Writer.Error!void {
    var requires_leading_and = false;
    for (@typeInfo(Params).@"struct".fields) |field| {
        if (requires_leading_and) {
            try writer.writeAll(" AND ");
        }
        try sql_escape.writeEscapedIdentifier(writer, field.name);
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
    return Where(
        comptimeExpressionFromParams(Params),
        meta.TupleFromStruct(Params),
    );
}

pub fn fromParams(params: anytype) FromParams(@TypeOf(params)) {
    return .{ .params = meta.structToTuple(params) };
}

pub fn Merged(comptime Lhs: type, comptime Rhs: type, comptime operator: []const u8) type {
    return Where(
        "(" ++ Lhs.expression ++ ") " ++ operator ++ " (" ++ Rhs.expression ++ ")",
        meta.MergedTuples(Lhs.Params, Rhs.Params),
    );
}
