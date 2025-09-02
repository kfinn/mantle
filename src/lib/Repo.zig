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
        const fields = @typeInfo(RelationAttributesBeforeDbCast(relation)).@"struct".fields;
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

pub fn CastResult(comptime T: type) type {
    return union(enum) {
        success: T,
        failure: void,
    };
}

fn ChangeSetAfterRelationAttributesCast(comptime relation: type, comptime ChangeSet: type) type {
    if (!@hasDecl(ChangeSet, "casts")) return ChangeSet;

    const relation_fields = @typeInfo(relation.Attributes).@"struct".fields;
    const change_set_fields = @typeInfo(ChangeSet).@"struct".fields;

    var change_set_after_cast_fields_buffer: [relation_fields.len]std.builtin.Type.StructField = undefined;
    var next_change_set_after_cast_field_index = 0;
    relation_field: inline for (relation_fields) |relation_field| {
        if (std.meta.hasFn(ChangeSet.casts, relation_field.name)) {
            change_set_after_cast_fields_buffer[next_change_set_after_cast_field_index] = .{
                .name = relation_field.name,
                .type = std.meta.fieldInfo(relation.Attributes, std.meta.stringToEnum(std.meta.FieldEnum(relation.Attributes), relation_field.name).?).type,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = relation_field.alignment,
            };
            next_change_set_after_cast_field_index += 1;
            continue :relation_field;
        }

        for (change_set_fields) |change_set_field| {
            if (std.mem.eql(u8, relation_field.name, change_set_field.name)) {
                change_set_after_cast_fields_buffer[next_change_set_after_cast_field_index] = relation_field;
                next_change_set_after_cast_field_index += 1;
                continue :relation_field;
            }
        }
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = change_set_after_cast_fields_buffer[0..next_change_set_after_cast_field_index],
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = false,
    } });
}

fn InsertFromRelation(comptime relation: type, comptime ChangeSet: type) type {
    const ConcreteChangeSetAfterRelationAttributesCast = ChangeSetAfterRelationAttributesCast(relation, ChangeSet);
    const ConcreteChangeSetAfterDbCast = ChangeSetAfterDbCast(relation, ConcreteChangeSetAfterRelationAttributesCast);

    const relation_fields = @typeInfo(relation.Attributes).@"struct".fields;
    var returning_buf: [relation_fields.len]sql.Output = undefined;
    for (relation_fields, 0..) |field, index| {
        returning_buf[index] = .fromColumn(field.name);
    }
    const returning = returning_buf;

    return sql.insert.Insert(
        if (@hasField(relation, "from")) relation.from else .fromTable(relativeTypeName(@typeName(relation))),
        ConcreteChangeSetAfterDbCast,
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
    const ConcreteChangeSetAfterRelationAttributesCast = ChangeSetAfterRelationAttributesCast(relation, ChangeSet);
    const ConcreteChangeSetAfterDbCast = ChangeSetAfterDbCast(relation, ConcreteChangeSetAfterRelationAttributesCast);

    if (ChangeSet == ConcreteChangeSetAfterDbCast) {
        return .{ .change_set = change_set };
    }

    var change_set_after_relation_attributes_cast: ConcreteChangeSetAfterRelationAttributesCast = undefined;
    if (ChangeSet == ConcreteChangeSetAfterRelationAttributesCast) {
        change_set_after_relation_attributes_cast = change_set;
    } else {
        change_set_after_type_cast_field: inline for (@typeInfo(ConcreteChangeSetAfterRelationAttributesCast).@"struct".fields) |change_set_after_type_cast_field| {
            if (@hasDecl(ChangeSet, "casts") and std.meta.hasFn(ChangeSet.casts, change_set_after_type_cast_field.name)) {
                switch (try @field(ChangeSet.casts, change_set_after_type_cast_field.name)(change_set, self, errors)) {
                    .success => |value| {
                        @field(change_set_after_relation_attributes_cast, change_set_after_type_cast_field.name) = value;
                    },
                    .failure => {
                        return null;
                    },
                }
                continue :change_set_after_type_cast_field;
            }

            inline for (@typeInfo(ChangeSet).@"struct".fields) |change_set_field| {
                if (comptime std.mem.eql(u8, change_set_field.name, change_set_after_type_cast_field.name)) {
                    @field(change_set_after_relation_attributes_cast, change_set_after_type_cast_field.name) = @field(change_set, change_set_field.name);
                    continue :change_set_after_type_cast_field;
                }
            }
            unreachable;
        }

        if (errors.isInvalid()) {
            return null;
        }
    }

    if (ConcreteChangeSetAfterRelationAttributesCast == ConcreteChangeSetAfterDbCast) {
        return .{ .change_set = change_set_after_relation_attributes_cast };
    }
    return .{ .change_set = try changeSetAfterDbCast(self, relation, change_set_after_relation_attributes_cast) };
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

    const sql_update = updateFromRelation(self, relation, record.attributes.id, change_set);

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
        ChangeSetAfterDbCast(relation, ChangeSet),
        sql.where.Where("id = ?", struct { primaryKeyType(relation) }),
        &returning,
    );
}

fn updateFromRelation(self: *const @This(), comptime relation: type, id: primaryKeyType(relation), change_set: anytype) UpdateFromRelation(relation, @TypeOf(change_set)) {
    return .{
        .change_set = try changeSetAfterDbCast(self, relation, change_set),
        .where = .{ .params = .{id} },
    };
}

fn ChangeSetAfterDbCast(relation: type, ChangeSet: type) type {
    if (!@hasDecl(relation, "to_db_casts")) return ChangeSet;
    const change_set_fields = std.meta.fields(ChangeSet);
    var fields: [change_set_fields.len]std.builtin.Type.StructField = undefined;
    for (change_set_fields, 0..) |change_set_field, index| {
        if (std.meta.hasFn(relation.to_db_casts, change_set_field.name)) {
            fields[index] = .{
                .name = change_set_field.name,
                .type = @typeInfo(@typeInfo(@TypeOf(@field(relation.to_db_casts, change_set_field.name))).@"fn".return_type.?).error_union.payload,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = change_set_field.alignment,
            };
        } else {
            fields[index] = change_set_field;
        }
    }

    return @Type(.{ .@"struct" = .{
        .decls = &[_]std.builtin.Type.Declaration{},
        .fields = &fields,
        .is_tuple = false,
        .layout = .auto,
    } });
}

fn changeSetAfterDbCast(self: *const @This(), comptime relation: type, change_set: anytype) !ChangeSetAfterDbCast(relation, @TypeOf(change_set)) {
    var result: ChangeSetAfterDbCast(relation, @TypeOf(change_set)) = undefined;
    const casts = if (@hasDecl(relation, "to_db_casts")) relation.to_db_casts else struct {};
    inline for (std.meta.fields(@TypeOf(result))) |field| {
        if (std.meta.hasFn(casts, field.name)) {
            @field(result, field.name) = try @field(casts, field.name)(@field(change_set, field.name), self);
        } else {
            @field(result, field.name) = @field(change_set, field.name);
        }
    }
    return result;
}

fn RelationAttributesBeforeDbCast(relation: type) type {
    if (!@hasDecl(relation, "from_db_casts")) return relation.Attributes;
    const relation_fields = std.meta.fields(relation.Attributes);
    var fields: [relation_fields.len]std.builtin.Type.StructField = undefined;
    for (relation_fields, 0..) |relation_field, index| {
        if (std.meta.hasFn(relation.from_db_casts, relation_field.name)) {
            fields[index] = .{
                .name = relation_field.name,
                .type = @typeInfo(@TypeOf(@field(relation.from_db_casts, relation_field.name))).@"fn".params[0].type.?,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = relation_field.alignment,
            };
        } else {
            fields[index] = relation_field;
        }
    }

    return @Type(.{ .@"struct" = .{
        .decls = &[_]std.builtin.Type.Declaration{},
        .fields = &fields,
        .is_tuple = false,
        .layout = .auto,
    } });
}

fn rowToRelationResult(self: *const @This(), comptime relation: type, row: anytype) !relationResultType(relation) {
    var result: relationResultType(relation) = undefined;
    const AttributesBeforeDbCast = RelationAttributesBeforeDbCast(relation);
    const attributes_before_db_cast = try row.to(AttributesBeforeDbCast, .{ .dupe = true, .allocator = self.allocator });
    const casts = if (@hasDecl(relation, "from_db_casts")) relation.from_db_casts else struct {};
    inline for (std.meta.fields(@TypeOf(result.attributes))) |field| {
        if (std.meta.hasFn(casts, field.name)) {
            @field(result.attributes, field.name) = try @field(casts, field.name)(@field(attributes_before_db_cast, field.name), self);
        } else {
            @field(result.attributes, field.name) = @field(attributes_before_db_cast, field.name);
        }
    }
    return result;
}
