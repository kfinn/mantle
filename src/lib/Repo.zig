const std = @import("std");

const pg = @import("pg");
const inflector = @import("./inflector.zig");
const sql_escape = @import("./sql_escape.zig");
const validation = @import("./validation.zig");

const Options = struct {
    from: ?[]const u8 = null,
    Validator: ?type = null,
};

fn selectFieldsSqlCount(Record: type) usize {
    var requires_leading_comma = false;
    var fields_sql_count: usize = 0;
    for (std.meta.fieldNames(Record)) |field_name| {
        fields_sql_count += sql_escape.escapedFieldCount(field_name);
        if (requires_leading_comma) {
            fields_sql_count += 2;
        }
        requires_leading_comma = true;
    }
    return fields_sql_count;
}

fn comptimeSelectFieldsSql(Record: type) *const [selectFieldsSqlCount(Record):0]u8 {
    var buf: [selectFieldsSqlCount(Record):0]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(&buf);
    var buf_writer = buf_stream.writer();

    var requires_leading_comma = false;
    for (std.meta.fieldNames(Record)) |field_name| {
        if (requires_leading_comma) {
            buf_writer.writeAll(", ") catch unreachable;
        }
        sql_escape.writeEscapedField(buf_writer, field_name) catch unreachable;
        requires_leading_comma = true;
    }
    buf[buf.len] = 0;
    const final = buf;
    return &final;
}

fn insertFieldsSqlCount(Record: type) usize {
    var requires_leading_comma = false;
    var fields_sql_count: usize = 0;
    for (std.meta.fieldNames(Record)) |field_name| {
        if (std.mem.eql(u8, field_name, "id")) continue;

        fields_sql_count += sql_escape.escapedFieldCount(field_name);
        if (requires_leading_comma) {
            fields_sql_count += 2;
        }
        requires_leading_comma = true;
    }
    return fields_sql_count;
}

fn comptimeInsertFieldsSql(Record: type) *const [insertFieldsSqlCount(Record):0]u8 {
    var buf: [insertFieldsSqlCount(Record):0]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(&buf);
    var buf_writer = buf_stream.writer();

    var requires_leading_comma = false;
    for (std.meta.fieldNames(Record)) |field_name| {
        if (std.mem.eql(u8, field_name, "id")) continue;

        if (requires_leading_comma) {
            buf_writer.writeAll(", ") catch unreachable;
        }
        sql_escape.writeEscapedField(buf_writer, field_name) catch unreachable;
        requires_leading_comma = true;
    }
    buf[buf.len] = 0;
    const final = buf;
    return &final;
}

fn insertPlaceholdersSqlCount(Record: type) usize {
    var requires_leading_comma = false;
    var current_placeholder_index = 1;
    var placeholders_sql_count: usize = 0;
    for (std.meta.fieldNames(Record)) |field_name| {
        if (std.mem.eql(u8, field_name, "id")) continue;

        if (requires_leading_comma) {
            placeholders_sql_count += 2;
        }
        placeholders_sql_count += std.fmt.count("${d}", .{current_placeholder_index});
        requires_leading_comma = true;
        current_placeholder_index += 1;
    }
    return placeholders_sql_count;
}

fn comptimeInsertPlaceholdersSql(Record: type) *const [insertPlaceholdersSqlCount(Record):0]u8 {
    var buf: [insertPlaceholdersSqlCount(Record):0]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(&buf);
    var buf_writer = buf_stream.writer();

    var requires_leading_comma = false;
    var current_placeholder_index: usize = 1;
    for (std.meta.fieldNames(Record)) |field_name| {
        if (std.mem.eql(u8, field_name, "id")) continue;

        if (requires_leading_comma) {
            buf_writer.writeAll(", ") catch unreachable;
        }
        std.fmt.format(buf_writer, "${d}", .{current_placeholder_index}) catch unreachable;
        current_placeholder_index += 1;
        requires_leading_comma = true;
    }
    buf[buf.len] = 0;
    const final = buf;
    return &final;
}

fn relativeTypeName(type_name: [:0]const u8) [:0]const u8 {
    var last_dot_index = 0;
    for (type_name, 0..) |c, index| {
        if (c == '.') {
            last_dot_index = index;
        }
    }
    return type_name[last_dot_index + 1 ..];
}

const query_and = " AND ";

fn queryStructToSqlCount(Query: type, comptime start_index: usize) usize {
    var requires_leading_and = false;
    var count = 0;
    inline for (std.meta.fieldNames(Query), start_index..) |field_name, index| {
        if (requires_leading_and) {
            count += query_and.len;
        }
        count += sql_escape.escapedFieldCount(field_name);
        count += std.fmt.count(" = ${d}", .{index});
        requires_leading_and = true;
    }
    return count;
}

fn comptimeQueryStructToSql(comptime Query: type, comptime start_index: usize) [queryStructToSqlCount(Query, start_index):0]u8 {
    var buf: [queryStructToSqlCount(Query, start_index):0]u8 = undefined;
    var buf_stream = std.io.fixedBufferStream(&buf);
    var buf_writer = buf_stream.writer();

    var requires_leading_and = false;
    for (std.meta.fieldNames(Query), start_index..) |field_name, index| {
        if (requires_leading_and) {
            buf_writer.writeAll(query_and) catch unreachable;
        }
        sql_escape.writeEscapedField(buf_writer, field_name) catch unreachable;
        buf_writer.print(" = ${d}", .{index}) catch unreachable;
        requires_leading_and = true;
    }

    buf[buf.len] = 0;
    return buf;
}

fn structTypeToTupleType(comptime Query: type) type {
    const fields = std.meta.fields(Query);
    var types: [fields.len]type = undefined;
    inline for (fields, 0..) |field, index| {
        types[index] = field.type;
    }
    return std.meta.Tuple(&types);
}

fn structToTuple(query: anytype) structTypeToTupleType(@TypeOf(query)) {
    var tuple: structTypeToTupleType(@TypeOf(query)) = undefined;
    inline for (comptime std.meta.fieldNames(@TypeOf(query)), 0..) |field_name, index| {
        tuple[index] = @field(query, field_name);
    }
    return tuple;
}

const empty_decls = [_]std.builtin.Type.Declaration{};

fn AbstractNewRecord(comptime Record: type) type {
    const record_fields = std.meta.fields(Record);
    var non_id_fields_count = 0;
    for (record_fields) |record_field| {
        if (std.mem.eql(u8, record_field.name, "id")) {
            continue;
        }
        non_id_fields_count += 1;
    }

    var new_record_fields: [non_id_fields_count]std.builtin.Type.StructField = undefined;
    var next_new_record_field_index = 0;
    for (record_fields) |record_field| {
        if (std.mem.eql(u8, record_field.name, "id")) {
            continue;
        }
        new_record_fields[next_new_record_field_index] = record_field;
        next_new_record_field_index += 1;
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &new_record_fields,
        .decls = &empty_decls,
        .is_tuple = false,
    } });
}

pub fn Repo(comptime Record: type, comptime options: Options) type {
    const from = options.from orelse inflector.comptimeTableize(relativeTypeName(@typeName(Record)));
    const select_fields_sql = comptimeSelectFieldsSql(Record);
    const select_from_sql = std.fmt.comptimePrint("SELECT {s} FROM \"{s}\"", .{ select_fields_sql, from });

    return struct {
        pub fn find(conn: *pg.Conn, allocator: std.mem.Allocator, id: i64) !Record {
            const find_sql = std.fmt.comptimePrint("{s} WHERE \"id\" = $1", .{select_from_sql});

            if (try conn.rowOpts(find_sql, .{id}, .{ .allocator = allocator })) |row| {
                return try row.to(Record, .{});
            }
            return error.NotFound;
        }

        pub fn findBy(conn: *pg.Conn, allocator: std.mem.Allocator, query: anytype) !?Record {
            const find_by_sql = std.fmt.comptimePrint("{s} WHERE {s}", comptime .{ select_from_sql, comptimeQueryStructToSql(@TypeOf(query), 1) });

            if (try conn.rowOpts(find_by_sql, structToTuple(query), .{ .allocator = allocator })) |row| {
                return try row.to(Record, .{});
            }
            return null;
        }

        pub fn all(conn: *pg.Conn, allocator: std.mem.Allocator) ![]Record {
            var all_builder = std.ArrayList(Record).init(allocator);
            var rows = try conn.queryOpts(select_from_sql, .{}, .{ .allocator = allocator });
            while (try rows.next()) |row| {
                try all_builder.append(try row.to(Record, .{}));
            }
            return try all_builder.toOwnedSlice();
        }

        pub fn create(conn: *pg.Conn, allocator: std.mem.Allocator, new_record: NewRecord) !Record {
            const errors = try validate(allocator, new_record);
            if (errors.isInvalid()) {
                return error.RecordInvalid;
            }

            const insert_into_sql = comptime std.fmt.comptimePrint(
                "INSERT INTO {s} ({s}) VALUES ({s}) RETURNING {s}",
                .{
                    from,
                    comptimeInsertFieldsSql(Record),
                    comptimeInsertPlaceholdersSql(Record),
                    select_fields_sql,
                },
            );

            if (try conn.rowOpts(insert_into_sql, structToTuple(new_record), .{ .allocator = allocator })) |row| {
                return try row.to(Record, .{});
            }
            return error.UnknownError;
        }

        pub fn validate(allocator: std.mem.Allocator, record: anytype) !validation.RecordErrors(@TypeOf(record)) {
            std.debug.assert(@TypeOf(record) == Record or @TypeOf(record) == NewRecord);

            if (options.Validator) |Validator| {
                return try Validator.validate(record, allocator);
            }
            return validation.RecordErrors(@TypeOf(record)).init(allocator);
        }

        pub const NewRecord = AbstractNewRecord(Record);
        pub const Errors = validation.RecordErrors(Record);
        pub const NewRecordErrors = validation.RecordErrors(NewRecord);
    };
}
