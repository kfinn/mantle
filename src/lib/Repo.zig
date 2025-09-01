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

fn isPrimaryKey(relation: type, field_name: []const u8) bool {
    _ = relation;
    return std.mem.eql(u8, field_name, "id");
}

fn primaryKeyType(relation: type) type {
    for (@typeInfo(relation.Attributes).@"struct".fields) |field| {
        if (isPrimaryKey(relation, field.name)) {
            return field.type;
        }
    }
    unreachable;
}

pub fn relationResultType(comptime relation: type) type {
    return struct {
        attributes: relation.Attributes,
        helpers: if (@hasDecl(relation, "helpers")) relation.helpers(@This(), "helpers") else struct {},
    };
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
    return findBy(self, relation, .{ .id = id }) orelse error.NotFound;
}

pub fn findBy(self: *const @This(), comptime relation: type, params: anytype) !?relationResultType(relation) {
    const select = selectFromRelation(relation, sql.where.fromParams(params), 1);
    var opt_row = try self.conn.rowOpts(
        @TypeOf(select).toSql(),
        select.params(),
        .{ .allocator = self.allocator },
    );
    if (opt_row) |*row| {
        const result = try self.rowToRelationResult(relation, row);
        try row.deinit();
        return result;
    }
    return null;
}

pub fn all(self: *const @This(), comptime relation: type) ![]relationResultType(relation) {
    const select = selectFromRelation(relation, sql.where.Where("TRUE", std.meta.Tuple(&[_]type{})){ .params = .{} }, null);
    var query_result = try self.conn.queryOpts(
        @TypeOf(select).toSql(),
        select.params(),
        .{ .allocator = self.allocator },
    );
    defer query_result.deinit();
    var array_list: std.ArrayList(relationResultType(relation)) = .{};
    while (try query_result.next()) |row| {
        try array_list.append(self.allocator, try self.rowToRelationResult(relation, &row));
    }
    return try array_list.toOwnedSlice(self.allocator);
}

fn SelectFromRelation(comptime relation: type, comptime WhereParam: ?type, has_limit: bool) type {
    const outputs = comptime outputs: {
        const fields = @typeInfo(relation.Attributes).@"struct".fields;
        var outputs_buf: [fields.len]sql.Output = undefined;
        for (fields, 0..) |field, field_index| {
            outputs_buf[field_index] = .fromColumn(field.name);
        }
        break :outputs outputs_buf;
    };

    return sql.select.Select(
        &outputs,
        if (@hasField(relation, "from")) relation.from else .fromTable(relativeTypeName(@typeName(relation))),
        WhereParam orelse sql.where.Where("TRUE", std.meta.Tuple(&[_]type{})),
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

fn CreateResult(comptime relation: type, comptime ChangeSet: type) type {
    return union(enum) {
        success: relationResultType(relation),
        failure: validation.RecordErrors(ChangeSet),
    };
}

pub fn create(self: *const @This(), comptime relation: type, change_set: anytype) !CreateResult(relation, @TypeOf(change_set)) {
    var errors: validation.RecordErrors(@TypeOf(change_set)) = .init(self.allocator);
    const insert = try self.insertFromRelation(relation, change_set, &errors) orelse return .{ .failure = errors };

    if (std.meta.hasFn(relation, "validate")) {
        var errors_after_cast: validation.RecordErrors(@TypeOf(insert.change_set)) = .init(self.allocator);
        try relation.validate(insert.change_set, &errors_after_cast);
        if (errors_after_cast.isInvalid()) {
            if (@TypeOf(errors) == @TypeOf(errors_after_cast)) {
                return .{ .failure = errors_after_cast };
            } else {
                try change_set.errorsAfterCast(&errors_after_cast, &errors);
                return .{ .failure = errors };
            }
        }
    }

    var row = try self.conn.rowOpts(
        @TypeOf(insert).toSql(),
        insert.params(),
        .{ .allocator = self.allocator },
    ) orelse return error.UnknownInsertError;
    const result = try self.rowToRelationResult(relation, &row);
    try row.deinit();
    return .{ .success = result };
}

pub fn CastResult(comptime relation: type, comptime field: std.meta.FieldEnum(relation.Attributes)) type {
    return union(enum) {
        success: std.meta.fieldInfo(relation.Attributes, field).type,
        failure: void,
    };
}

fn InsertFromRelation(comptime relation: type, comptime ChangeSet: type) type {
    const relation_fields = @typeInfo(relation.Attributes).@"struct".fields;
    const ChangeSetAfterCast = if (@hasDecl(ChangeSet, "cast_fields")) change_set_after_cast: {
        const change_set_fields = @typeInfo(ChangeSet).@"struct".fields;

        var change_set_after_cast_fields_buffer: [relation_fields.len]std.builtin.Type.StructField = undefined;
        var next_change_set_after_cast_field_index = 0;
        relation_field: inline for (relation_fields) |relation_field| {
            inline for (ChangeSet.cast_fields) |cast_field| {
                if (std.mem.eql(u8, relation_field.name, @tagName(cast_field))) {
                    change_set_after_cast_fields_buffer[next_change_set_after_cast_field_index] = relation_field;
                    next_change_set_after_cast_field_index += 1;
                    continue :relation_field;
                }
            }

            for (change_set_fields) |change_set_field| {
                if (std.mem.eql(u8, relation_field.name, change_set_field.name)) {
                    change_set_after_cast_fields_buffer[next_change_set_after_cast_field_index] = relation_field;
                    next_change_set_after_cast_field_index += 1;
                    continue :relation_field;
                }
            }
        }

        break :change_set_after_cast @Type(.{ .@"struct" = .{
            .layout = .auto,
            .fields = change_set_after_cast_fields_buffer[0..next_change_set_after_cast_field_index],
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        } });
    } else ChangeSet;

    var returning_buf: [relation_fields.len]sql.Output = undefined;
    for (relation_fields, 0..) |field, index| {
        returning_buf[index] = .fromColumn(field.name);
    }
    const returning = returning_buf;

    return sql.insert.Insert(
        if (@hasField(relation, "from")) relation.from else .fromTable(relativeTypeName(@typeName(relation))),
        ChangeSetAfterCast,
        &returning,
    );
}

fn insertFromRelation(
    self: *const @This(),
    comptime relation: type,
    change_set: anytype,
    errors: *validation.RecordErrors(@TypeOf(change_set)),
) !?InsertFromRelation(relation, @TypeOf(change_set)) {
    const ChangeSet = @TypeOf(change_set);
    const ChangeSetAfterCast = InsertFromRelation(relation, @TypeOf(change_set)).ChangeSet;
    if (ChangeSet == ChangeSetAfterCast) {
        return .{ .change_set = change_set };
    }

    var change_set_after_cast: ChangeSetAfterCast = undefined;
    change_set_after_type_cast_field: inline for (@typeInfo(ChangeSetAfterCast).@"struct".fields) |change_set_after_type_cast_field| {
        if (@hasDecl(ChangeSet, "cast_fields")) {
            inline for (ChangeSet.cast_fields) |change_set_cast_field| {
                if (comptime std.mem.eql(u8, @tagName(change_set_cast_field), change_set_after_type_cast_field.name)) {
                    switch (try change_set.castField(change_set_cast_field, self, errors)) {
                        .success => |value| {
                            @field(change_set_after_cast, change_set_after_type_cast_field.name) = value;
                        },
                        .failure => {
                            return null;
                        },
                    }
                    continue :change_set_after_type_cast_field;
                }
            }
        }

        inline for (@typeInfo(ChangeSet).@"struct".fields) |change_set_field| {
            if (comptime std.mem.eql(u8, change_set_field.name, change_set_after_type_cast_field.name)) {
                @field(change_set_after_cast, change_set_after_type_cast_field.name) = @field(change_set, change_set_field.name);
                continue :change_set_after_type_cast_field;
            }
        }
        unreachable;
    }

    if (errors.isValid()) {
        return .{ .change_set = change_set_after_cast };
    } else {
        return null;
    }
}

fn UpdateResult(comptime relation: type) type {
    return union(enum) {
        success: relationResultType(relation),
        failure: struct {
            record: relationResultType(relation),
            errors: validation.RecordErrors(relation.Attributes),
        },
    };
}

pub fn update(
    self: *const @This(),
    comptime relation: type,
    record: relationResultType(relation),
    change_set: anytype,
) !UpdateResult(relation) {
    const ChangeSet = @TypeOf(change_set);
    var updated_record: relationResultType(relation) = undefined;
    inline for (@typeInfo(@TypeOf(record.attributes)).@"struct".fields) |field| {
        @field(updated_record.attributes, field.name) = if (@hasField(ChangeSet, field.name)) @field(change_set, field.name) else @field(record.attributes, field.name);
    }

    if (std.meta.hasFn(relation, "validate")) {
        var errors: validation.RecordErrors(@TypeOf(updated_record.attributes)) = .init(self.allocator);
        try relation.validate(updated_record.attributes, &errors);
        if (errors.isInvalid()) {
            return .{ .failure = .{ .errors = errors, .record = updated_record } };
        }
    }

    const sql_update = updateFromRelation(relation, record.attributes.id, change_set);

    var row = try self.conn.rowOpts(
        @TypeOf(sql_update).toSql(),
        sql_update.params(),
        .{ .allocator = self.allocator },
    ) orelse return error.UnknownUpdateError;

    const result = try self.rowToRelationResult(relation, &row);
    try row.deinit();
    return .{ .success = result };
}

fn UpdateFromRelation(comptime relation: type, comptime ChangeSet: type) type {
    const relation_fields = @typeInfo(relation.Attributes).@"struct".fields;
    var returning_buf: [relation_fields.len]sql.Output = undefined;
    for (relation_fields, 0..) |field, index| {
        returning_buf[index] = .fromColumn(field.name);
    }
    const returning = returning_buf;

    return sql.update.Update(
        if (@hasField(relation, "from")) relation.from else .fromTable(relativeTypeName(@typeName(relation))),
        ChangeSet,
        sql.where.Where("id = ?", struct { primaryKeyType(relation) }),
        &returning,
    );
}

fn updateFromRelation(comptime relation: type, id: primaryKeyType(relation), change_set: anytype) UpdateFromRelation(relation, @TypeOf(change_set)) {
    return .{
        .change_set = change_set,
        .where = .{ .params = .{id} },
    };
}

fn rowToRelationResult(self: *const @This(), comptime relation: type, row: anytype) !relationResultType(relation) {
    var result: relationResultType(relation) = undefined;
    result.attributes = try row.to(relation.Attributes, .{ .dupe = true, .allocator = self.allocator });
    return result;
}
