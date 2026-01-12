const std = @import("std");

fn count(comptime Sql: type) usize {
    @setEvalBranchQuota(100000);

    var discarding_writer: std.Io.Writer.Discarding = .init(&.{});
    var next_placeholder: usize = 1;
    Sql.writeToSql(&discarding_writer.writer, &next_placeholder) catch unreachable;
    return discarding_writer.fullCount();
}

pub fn comptimeToSql(comptime Sql: type) *const [count(Sql):0]u8 {
    @setEvalBranchQuota(100000);

    const sql: [count(Sql):0]u8 = comptime sql: {
        var buf: [count(Sql):0]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        var next_placeholder: usize = 1;
        Sql.writeToSql(&writer, &next_placeholder) catch unreachable;
        buf[buf.len] = 0;
        break :sql buf;
    };
    return &sql;
}
