const std = @import("std");

pub const EmptyParams = std.meta.Tuple(&[_]type{});
pub const empty_params = EmptyParams{};

pub const Empty = struct {
    pub const Params = EmptyParams;

    pub fn params() Params {
        return empty_params;
    }
};

pub fn ParameterizedSnippet(comptime snippet_param: []const u8, ParamsParam: type) type {
    return struct {
        pub const snippet = snippet_param;
        pub const Params = ParamsParam;

        params: Params,

        pub fn writeToSql(writer: *std.Io.Writer, next_placeholder: *usize) std.Io.Writer.Error!void {
            try writeToSqlWithPlaceholders(writer, snippet, next_placeholder);
        }
    };
}

pub fn writeToSqlWithPlaceholders(writer: *std.Io.Writer, sql: []const u8, next_placeholder: *usize) std.Io.Writer.Error!void {
    for (sql) |c| {
        if (c == '?') {
            try writer.print("${d}", .{next_placeholder.*});
            next_placeholder.* += 1;
        } else {
            try writer.writeByte(c);
        }
    }
}
