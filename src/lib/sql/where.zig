const std = @import("std");

const meta = @import("../meta.zig");
const sql_escape = @import("escape.zig");

pub fn Where(comptime expression_param: []const u8, comptime ParamsParam: type, comptime children_param: ?struct { type, type }) type {
    return struct {
        pub const children: ?struct { type, type } = children_param;
        pub const expression = expression_param;
        pub const Params = ParamsParam;

        params: Params,

        pub fn merge(lhs: anytype, rhs: anytype, comptime operator: []const u8) Merged(@TypeOf(lhs), @TypeOf(rhs), operator) {
            const params: Merged(@TypeOf(lhs), @TypeOf(rhs)).Params = undefined;
            inline for (@typeInfo(lhs.Params).@"struct".fields) |field| {
                @field(params, field.name) = @field(lhs.params, field.name);
            }
            inline for (@typeInfo(rhs.Params).@"struct".fields, 0..) |field, field_index| {
                @field(params, std.fmt.comptimePrint("{d}", .{field_index + lhs.params.len})) = @field(rhs, field.name);
            }

            return .{ .params = params };
        }

        pub fn writeToSql(writer: anytype, next_placeholder: *usize) @TypeOf(writer).Error!void {
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
        }
    };
}

pub fn fromExpression(comptime expression: []const u8, params: anytype) Where(expression, @TypeOf(params), null) {
    return .{ .params = params };
}

fn writeExpressionFromParams(writer: anytype, comptime Params: type) @TypeOf(writer).Error!void {
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
    var counting_writer = std.io.countingWriter(std.io.null_writer);
    writeExpressionFromParams(counting_writer.writer(), Params) catch unreachable;
    return counting_writer.bytes_written;
}

fn comptimeExpressionFromParams(comptime Params: type) *const [expressionFromParamsCount(Params):0]u8 {
    comptime {
        var buf: [expressionFromParamsCount(Params):0]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();
        writeExpressionFromParams(writer, Params) catch unreachable;
        buf[buf.len] = 0;

        const final = buf;
        return &final;
    }
}

pub fn FromParams(comptime Params: type) type {
    return Where(
        comptimeExpressionFromParams(Params),
        meta.TupleFromStruct(Params),
        null,
    );
}

pub fn fromParams(params: anytype) FromParams(@TypeOf(params)) {
    return .{ .params = meta.structToTuple(params) };
}

fn MergedParams(comptime LhsParams: type, comptime RhsParams: type) type {
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = @typeInfo(LhsParams).@"struct".fields ++ @typeInfo(RhsParams).@"struct".fields,
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = true,
    } });
}

pub fn Merged(comptime Lhs: type, comptime Rhs: type, comptime operator: []const u8) type {
    return Where(
        "(" ++ Lhs.expression ++ ") " ++ operator ++ " (" ++ Rhs.expression ++ ")",
        struct { lhs_params: Lhs.Params, rhs_params: Rhs.Params },
        .{ Lhs, Rhs },
    );
}
