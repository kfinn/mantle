const std = @import("std");

const pg = @import("pg");

const inflector = @import("inflector.zig");
const sql = @import("sql.zig");
const validation = @import("validation.zig");

allocator: std.mem.Allocator,
conn: *pg.Conn,

pub fn init(allocator: std.mem.Allocator, conn: *pg.Conn) @This() {
    return .{ .allocator = allocator, .conn = conn };
}

pub fn deinit(self: *@This()) void {
    self.conn.release();
}

inline fn primaryKeyType(relation: anytype) type {
    for (@typeInfo(relation).@"struct".fields) |field| {
        if (std.mem.eql(u8, field.name, "id")) {
            return field.type;
        }
    }
    unreachable;
}

inline fn relationResultType(comptime relation: type) type {
    return relation.Record;
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

pub fn find(self: *const @This(), comptime relation: type, id: primaryKeyType(relation)) !relationResultType(relation) {
    const select = selectFromRelation(relation, sql.where.fromExpression("id = ?", .{id}), 1);
    const row = try self.conn.rowOpts(
        @TypeOf(select).toSql(),
        select.params(),
        .{ .allocator = self.allocator },
    ) orelse return error.NotFound;
    return try row.to(relationResultType(relation), .{});
}

pub fn findBy(self: *const @This(), comptime relation: type, params: anytype) !?relationResultType(relation) {
    const select = selectFromRelation(relation, sql.where.fromParams(params), 1);
    const opt_row = try self.conn.rowOpts(
        @TypeOf(select).toSql(),
        select.params(),
        .{ .allocator = self.allocator },
    );
    if (opt_row) |row| {
        return try row.to(relationResultType(relation), .{});
    }
    return null;
}

pub fn all(self: *const @This(), comptime relation: type) ![]relationResultType(relation) {
    const select = selectFromRelation(relation, sql.where.Where("TRUE", std.meta.Tuple(&[_]type{}), null){ .params = .{} }, null);
    const result = try self.conn.queryOpts(
        @TypeOf(select).toSql(),
        select.params(),
        .{ .allocator = self.allocator },
    );
    var array_list: std.ArrayList(relationResultType(relation)) = .{};
    while (try result.next()) |row| {
        try array_list.append(self.allocator, try row.to(relationResultType(relation), .{ .dupe = true }));
    }
    return try array_list.toOwnedSlice(self.allocator);
}

fn SelectFromRelation(comptime relation: type, comptime WhereParam: ?type, has_limit: bool) type {
    const outputs = comptime outputs: {
        const fields = @typeInfo(relationResultType(relation)).@"struct".fields;
        var outputs_buf: [fields.len]sql.Output = undefined;
        for (fields, 0..) |field, field_index| {
            outputs_buf[field_index] = .fromColumn(field.name);
        }
        break :outputs outputs_buf;
    };

    return sql.select.Select(
        &outputs,
        if (@hasField(relation, "from")) relation.from else .fromTable(relativeTypeName(@typeName(relation))),
        WhereParam orelse sql.where.Where("true", struct {}, false),
        has_limit,
    );
}

fn selectFromRelation(comptime relation: type, where: anytype, comptime opt_limit: ?usize) SelectFromRelation(
    relation,
    @TypeOf(where),
    if (opt_limit) |_| true else false,
) {
    return .{
        .where = where,
        .limit = if (opt_limit) |limit| limit else void{},
    };
}

pub fn create(self: *const @This(), comptime relation: type, values: anytype) !relationResultType(relation) {
    if (std.meta.hasFn(relation, "validate")) {
        const errors = try relation.validate(self.allocator, values);
        if (errors.isInvalid()) {
            return error.RecordInvalid;
        }
    }

    const insert = insertFromRelation(relation, values);

    const row = try self.conn.rowOpts(
        @TypeOf(insert).toSql(),
        insert.params(),
        .{ .allocator = self.allocator },
    ) orelse return error.UnknownInsertError;
    return try row.to(relationResultType(relation), .{});
}

fn InsertFromRelation(comptime relation: type, comptime ValuesParam: type) type {
    const relation_fields = @typeInfo(relationResultType(relation)).@"struct".fields;
    var returning_buf: [relation_fields.len]sql.Output = undefined;
    for (relation_fields, 0..) |field, index| {
        returning_buf[index] = .fromColumn(field.name);
    }
    const returning = returning_buf;

    return sql.insert.Insert(
        if (@hasField(relation, "from")) relation.from else .fromTable(relativeTypeName(@typeName(relation))),
        ValuesParam,
        &returning,
    );
}

fn insertFromRelation(comptime relation: type, values: anytype) InsertFromRelation(relation, @TypeOf(values)) {
    return .{ .values = values };
}
