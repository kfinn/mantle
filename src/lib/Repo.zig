const std = @import("std");

const pg = @import("pg");

const Association = @import("Association.zig");
const inflector = @import("inflector.zig");
const sql = @import("sql.zig");
const validation = @import("validation.zig");

const DbTransaction = union(enum) {
    transaction: void,
    savepoint: struct {
        index: usize,
        name: []const u8,
    },
};

const Transaction = struct {
    node: std.SinglyLinkedList.Node = .{},
    db_transaction: DbTransaction,
};

allocator: std.mem.Allocator,
conn: *pg.Conn,
transactions: std.SinglyLinkedList = .{},

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

pub const Preload = struct {
    name: []const u8,
    preloads: []const @This() = &[_]@This(){},
};

const ResultOptions = struct {
    preloads: []const Preload = &[_]Preload{},
};

fn findRelationAssociationByName(comptime relation: type, name: []const u8) Association {
    for (relation.associations) |association| {
        if (std.mem.eql(u8, association.name, name)) {
            return association;
        }
    }
    @compileError("unable to find association " ++ name ++ " from " ++ @typeName(relation));
}

fn Associations(comptime relation: type, comptime preloads: []const Preload) type {
    const associations_fields = comptime associations_fields: {
        var buf: [preloads.len]std.builtin.Type.StructField = undefined;
        for (preloads, 0..) |preload, index| {
            const association = findRelationAssociationByName(relation, preload.name);
            const SingularAssociaitonRelationResult = *relationResultTypeWithOpts(association.relation, .{ .preloads = preload.preloads });

            var name_with_sentinel: [preload.name.len:0]u8 = undefined;
            @memcpy(name_with_sentinel[0..preload.name.len], preload.name);
            name_with_sentinel[name_with_sentinel.len] = 0;
            buf[index] = .{
                .name = &name_with_sentinel,
                .type = switch (association.type) {
                    .has_many => []SingularAssociaitonRelationResult,
                    .belongs_to => SingularAssociaitonRelationResult,
                },
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = 1,
            };
        }
        const final = buf;
        break :associations_fields &final;
    };
    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = associations_fields,
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = false,
    } });
}

pub fn relationResultType(comptime relation: type) type {
    return struct {
        attributes: relation.Attributes,
        helpers: if (@hasDecl(relation, "helpers")) relation.helpers(@This(), "helpers") else struct {} = .{},
    };
}

fn relationResultTypeWithOpts(comptime relation: type, comptime opts: ResultOptions) type {
    return struct {
        attributes: relation.Attributes,
        associations: Associations(relation, opts.preloads),
        helpers: if (@hasDecl(relation, "helpers")) relation.helpers(@This(), "helpers") else struct {} = .{},
    };
}

pub fn find(self: *const @This(), comptime relation: type, id: primaryKeyType(relation)) !relationResultType(relation) {
    return try findBy(self, relation, .{ .id = id }) orelse error.NotFound;
}

pub fn findBy(self: *const @This(), comptime relation: type, params: anytype) !?relationResultType(relation) {
    const select = selectFromRelation(
        relation,
        .{
            .where = sql.where.fromParams(params),
            .limit = 1,
        },
    );
    var opt_row = try self.conn.rowOpts(
        @TypeOf(select).toSql(),
        select.params(),
        .{ .allocator = self.allocator },
    );
    if (opt_row) |*row| {
        const result: relationResultType(relation) = .{ .attributes = try self.rowToAttributes(relation, row) };
        try row.deinit();
        return result;
    }
    return null;
}

pub fn all(
    self: *const @This(),
    comptime relation: type,
    opts: anytype,
    comptime result_opts: ResultOptions,
) ![]relationResultTypeWithOpts(relation, result_opts) {
    const select = selectFromRelation(relation, opts);
    const results = if (self.conn.queryOpts(
        @TypeOf(select).toSql(),
        select.params(),
        .{ .allocator = self.allocator },
    )) |query_result| results_without_associations: {
        var array_list: std.ArrayList(relationResultTypeWithOpts(relation, result_opts)) = .{};
        while (try query_result.next()) |row| {
            try array_list.append(self.allocator, undefined);
            array_list.items[array_list.items.len - 1].attributes = try rowToAttributes(self, relation, row);
        }
        query_result.deinit();

        break :results_without_associations try array_list.toOwnedSlice(self.allocator);
    } else |err| {
        switch (err) {
            error.PG => {
                if (self.conn.err) |pg_err| {
                    std.log.err("PG {s}\n", .{pg_err.message});
                }
            },
            else => {},
        }
        return err;
    };

    try populatePreloads(self, result_opts.preloads, relation, results);

    return results;
}

fn populatePreloads(
    self: *const @This(),
    comptime preloads: []const Preload,
    comptime relation: type,
    records: []relationResultTypeWithOpts(relation, .{ .preloads = preloads }),
) !void {
    inline for (preloads) |preload| {
        const association = comptime findRelationAssociationByName(relation, preload.name);
        const association_records = try self.all(
            association.relation,
            .{ .where = try association.preloadedFromRelationWhere(relation, records, self) },
            .{ .preloads = preload.preloads },
        );
        try association.populate(
            relation,
            records,
            association_records,
            self,
        );
    }
}

fn OutputListFromRelation(comptime relation: type) type {
    const output_types: []const type = comptime output_types: {
        const fields = @typeInfo(RelationAttributesBeforeDbCast(relation)).@"struct".fields;
        var types_buf: [fields.len]type = undefined;
        for (fields, 0..) |field, field_index| {
            types_buf[field_index] = sql.output.Column(field.name);
        }
        const types = types_buf;
        break :output_types &types;
    };
    return sql.OutputList(output_types);
}

fn outputListFromRelation(comptime relation: type) OutputListFromRelation(relation) {
    var outputList: OutputListFromRelation(relation) = undefined;
    inline for (@typeInfo(@TypeOf(outputList.outputs)).@"struct".fields) |field| {
        @field(outputList.outputs, field.name) = .{ .expression = .{ .params = .{} } };
    }
    return outputList;
}

fn SelectFromRelation(
    comptime relation: type,
    comptime opts: struct {
        Where: ?type,
        has_limit: bool,
        has_offset: bool,
    },
) type {
    @setEvalBranchQuota(1000000);

    return sql.Select(.{
        .OutputList = OutputListFromRelation(relation),
        .From = sql.from.Table(inflector.relationNameFromType(relation)),
        .Where = opts.Where,
        .has_limit = opts.has_limit,
        .has_offset = opts.has_offset,
    });
}

fn selectFromRelation(
    comptime relation: type,
    opts: anytype,
) SelectFromRelation(
    relation,
    .{
        .Where = if (@hasField(@TypeOf(opts), "where")) @TypeOf(opts.where) else null,
        .has_limit = @hasField(@TypeOf(opts), "limit"),
        .has_offset = @hasField(@TypeOf(opts), "offset"),
    },
) {
    @setEvalBranchQuota(1000000);

    return .{
        .output_list = outputListFromRelation(relation),
        .from = .{ .expression = .{ .params = .{} } },
        .where = if (@hasField(@TypeOf(opts), "where")) opts.where else .{},
        .limit = if (@hasField(@TypeOf(opts), "limit")) .{ .expression = .{ .params = .{opts.limit} } } else .{},
        .offset = if (@hasField(@TypeOf(opts), "offset")) .{ .expression = .{ .params = .{opts.offset} } } else .{},
    };
}

pub fn CreateResult(comptime relation: type, comptime ChangeSet: type) type {
    return union(enum) {
        success: relationResultType(relation),
        failure: validation.RecordErrors(ChangeSet),
    };
}

pub fn create(
    self: *const @This(),
    comptime relation: type,
    change_set: anytype,
) !CreateResult(relation, @TypeOf(change_set)) {
    var errors: validation.RecordErrors(@TypeOf(change_set)) = .init(self.allocator);
    const change_set_after_type_cast = try self.typeCastedChangeSet(relation, change_set, &errors) orelse return .{ .failure = errors };

    if (std.meta.hasFn(relation, "validate")) {
        var change_set_after_type_cast_errors: validation.RecordErrors(@TypeOf(change_set_after_type_cast)) = .init(self.allocator);
        try relation.validate(change_set_after_type_cast, &change_set_after_type_cast_errors);
        if (change_set_after_type_cast_errors.isInvalid()) {
            for (change_set_after_type_cast_errors.base_errors.items) |base_error_after_type_cast| {
                try errors.addBaseError(base_error_after_type_cast);
            }
            const ChangeSetField = @TypeOf(errors).Field;
            const ChangeSetAfterTypeCastField = @TypeOf(change_set_after_type_cast_errors).Field;
            for (std.meta.fieldNames(ChangeSetAfterTypeCastField)) |field_name| {
                const change_set_after_type_cast_field = std.meta.stringToEnum(ChangeSetAfterTypeCastField, field_name).?;
                for (change_set_after_type_cast_errors.field_errors.get(change_set_after_type_cast_field).items) |field_error| {
                    if (std.meta.stringToEnum(ChangeSetField, field_name)) |change_set_field| {
                        try errors.addFieldError(change_set_field, field_error);
                    } else {
                        const updated_description = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ field_name, field_error.description });
                        try errors.addBaseError(.init(field_error.err, updated_description));
                    }
                }
            }
            return .{ .failure = errors };
        }
    }

    const sql_insert = try self.typeCastedChangeSetToInsert(
        relation,
        change_set_after_type_cast,
    );

    if (self.conn.rowOpts(
        @TypeOf(sql_insert).toSql(),
        sql_insert.params(),
        .{ .allocator = self.allocator },
    )) |opt_row| {
        if (opt_row == null) return error.UnknownInsertError;
        var row = opt_row.?;
        const result: relationResultType(relation) = .{ .attributes = try self.rowToAttributes(relation, &row) };
        row.deinit() catch {};
        return .{ .success = result };
    } else |err| {
        if (err == error.PG) {
            if (self.conn.err) |pg_err| {
                try errors.addBaseError(.init(err, pg_err.message));
                return .{ .failure = errors };
            }
        }

        try errors.addBaseError(.init(err, "unknown error"));
        return .{ .failure = errors };
    }
}

fn ChangeSetAfterRelationAttributesCast(comptime relation: type, comptime ChangeSet: type) type {
    @setEvalBranchQuota(1000000);

    const change_set_fields = @typeInfo(ChangeSet).@"struct".fields;
    const relation_fields = @typeInfo(relation.Attributes).@"struct".fields;
    var fields: [relation_fields.len]std.builtin.Type.StructField = undefined;
    var next_field_index = 0;
    field: for (change_set_fields) |change_set_field| {
        for (relation_fields) |relation_field| {
            if (std.mem.eql(u8, relation_field.name, change_set_field.name)) {
                fields[next_field_index] = relation_field;
                next_field_index += 1;
                continue :field;
            }
        }
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = fields[0..next_field_index],
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = false,
    } });
}

fn InsertFromRelation(comptime relation: type, comptime ChangeSet: type) type {
    @setEvalBranchQuota(1000000);

    return sql.Insert(.{
        .into = .table(inflector.relationNameFromType(relation)),
        .ChangeSet = ChangeSetAfterDbCast(relation, ChangeSet),
        .Returning = OutputListFromRelation(relation),
    });
}

fn typeCastedChangeSet(
    self: *const @This(),
    comptime relation: type,
    change_set_before_type_cast: anytype,
    errors: *validation.RecordErrors(@TypeOf(change_set_before_type_cast)),
) !?ChangeSetAfterRelationAttributesCast(relation, @TypeOf(change_set_before_type_cast)) {
    @setEvalBranchQuota(1000000);

    const ChangeSet = @TypeOf(change_set_before_type_cast);
    const ConcreteChangeSetAfterRelationAttributesCast = ChangeSetAfterRelationAttributesCast(relation, ChangeSet);

    if (ChangeSet == ConcreteChangeSetAfterRelationAttributesCast) {
        return change_set_before_type_cast;
    }

    var change_set_after_relation_attributes_cast: ConcreteChangeSetAfterRelationAttributesCast = undefined;
    if (ChangeSet == ConcreteChangeSetAfterRelationAttributesCast) {
        change_set_after_relation_attributes_cast = change_set_before_type_cast;
    } else {
        change_set_after_type_cast_field: inline for (@typeInfo(ConcreteChangeSetAfterRelationAttributesCast).@"struct".fields) |change_set_after_type_cast_field| {
            if (@hasDecl(ChangeSet, "casts") and std.meta.hasFn(ChangeSet.casts, change_set_after_type_cast_field.name)) {
                if (@field(ChangeSet.casts, change_set_after_type_cast_field.name)(change_set_before_type_cast, self, errors)) |value_after_cast| {
                    @field(change_set_after_relation_attributes_cast, change_set_after_type_cast_field.name) = value_after_cast;
                } else |err| switch (err) {
                    error.InvalidCast => {},
                    else => return err,
                }
                continue :change_set_after_type_cast_field;
            }

            inline for (@typeInfo(ChangeSet).@"struct".fields) |change_set_field| {
                if (comptime std.mem.eql(u8, change_set_field.name, change_set_after_type_cast_field.name)) {
                    switch (try self.builtinCast(change_set_field.type, change_set_after_type_cast_field, @field(change_set_before_type_cast, change_set_field.name))) {
                        .success => |value_after_type_cast| {
                            @field(change_set_after_relation_attributes_cast, change_set_after_type_cast_field.name) = value_after_type_cast;
                        },
                        .failure => |err| {
                            try errors.addFieldError(
                                std.meta.stringToEnum(@TypeOf(errors.*).Field, change_set_field.name).?,
                                err,
                            );
                        },
                    }
                    continue :change_set_after_type_cast_field;
                }
            }
            unreachable;
        }

        if (errors.isInvalid()) {
            return null;
        }
    }

    return change_set_after_relation_attributes_cast;
}

fn typeCastedChangeSetToInsert(
    self: *const @This(),
    comptime relation: type,
    change_set: anytype,
) !InsertFromRelation(relation, @TypeOf(change_set)) {
    @setEvalBranchQuota(1000000);

    return .{
        .change_set = try changeSetAfterDbCast(self, relation, change_set),
        .returning = outputListFromRelation(relation),
    };
}

pub fn CastResult(comptime ValueAfterTypeCast: type) type {
    return union(enum) {
        success: ValueAfterTypeCast,
        failure: validation.Error,
    };
}

fn builtinCast(
    self: *const @This(),
    comptime ValueBeforeTypeCast: type,
    comptime field_after_type_cast: std.builtin.Type.StructField,
    value_before_type_cast: ValueBeforeTypeCast,
) !CastResult(field_after_type_cast.type) {
    const ValueAfterTypeCast = field_after_type_cast.type;
    switch (@typeInfo(ValueAfterTypeCast)) {
        .@"struct" => {
            if (@hasDecl(ValueAfterTypeCast, "castFromInput")) {
                return try ValueAfterTypeCast.castFromInput(value_before_type_cast, self);
            }
        },
        .optional => |optional| {
            if (optional.child == ValueBeforeTypeCast) {
                return .{ .success = value_before_type_cast };
            }
            if (@hasDecl(optional.child, "castFromInput") and @hasDecl(optional.child, "isOptionalInputPresent")) {
                if (try optional.child.isOptionalInputPresent(value_before_type_cast)) {
                    return switch (try optional.child.castFromInput(value_before_type_cast, self)) {
                        .success => |success| .{ .success = success },
                        .failure => |failure| .{ .failure = failure },
                    };
                }
                return .{ .success = field_after_type_cast.defaultValue() orelse null };
            }
            switch (@typeInfo(optional.child)) {
                .bool => {
                    if (value_before_type_cast.len == 0) {
                        return .{ .success = field_after_type_cast.defaultValue() orelse null };
                    }
                    if (std.mem.eql(u8, "0", value_before_type_cast)) {
                        return .{ .success = false };
                    } else if (std.mem.eql(u8, "1", value_before_type_cast)) {
                        return .{ .success = true };
                    } else {
                        return .{ .failure = .init(error.InvalidFormat, "invalid boolean") };
                    }
                },
                .int => {
                    if (value_before_type_cast.len == 0) {
                        return .{ .success = field_after_type_cast.defaultValue() orelse null };
                    }
                    if (std.fmt.parseInt(optional.child, value_before_type_cast, 10)) |value_after_type_cast| {
                        return .{ .success = value_after_type_cast };
                    } else |err| {
                        return .{ .failure = .init(err, "invalid number") };
                    }
                },
                .float => {
                    if (value_before_type_cast.len == 0) {
                        return .{ .success = field_after_type_cast.defaultValue() orelse null };
                    }
                    if (std.fmt.parseFloat(optional.child, value_before_type_cast)) |value_after_type_cast| {
                        return .{ .success = value_after_type_cast };
                    } else |err| {
                        return .{ .failure = .init(err, "invalid number") };
                    }
                },
                .@"enum" => {
                    if (value_before_type_cast.len == 0) {
                        return .{ .success = field_after_type_cast.defaultValue() orelse null };
                    }
                    if (std.meta.stringToEnum(ValueAfterTypeCast, value_before_type_cast)) |value_after_type_cast| {
                        return .{ .success = value_after_type_cast };
                    } else {
                        return .{ .failure = .init(error.InvalidFormat, "invalid enum") };
                    }
                },
                else => {
                    @compileError("Cannot automatically cast type " ++ @typeName(ValueBeforeTypeCast) ++ " to " ++ @typeName(ValueAfterTypeCast));
                },
            }
        },
        .bool => {
            if (value_before_type_cast.len == 0) {
                if (field_after_type_cast.defaultValue()) |default_value| {
                    return .{ .success = default_value };
                }
                return .{ .failure = .init(error.Required, "required") };
            }
            if (std.mem.eql(u8, "0", value_before_type_cast)) {
                return .{ .success = false };
            } else if (std.mem.eql(u8, "1", value_before_type_cast)) {
                return .{ .success = true };
            } else {
                return .{ .failure = .init(error.InvalidFormat, "invalid boolean") };
            }
        },
        .int => {
            if (value_before_type_cast.len == 0) {
                if (field_after_type_cast.defaultValue()) |default_value| {
                    return .{ .success = default_value };
                }
                return .{ .failure = .init(error.Required, "required") };
            }
            if (std.fmt.parseInt(ValueAfterTypeCast, value_before_type_cast, 10)) |value_after_type_cast| {
                return .{ .success = value_after_type_cast };
            } else |err| {
                return .{ .failure = .init(err, "invalid number") };
            }
            return .{ .failure = .init(error.InvalidNumber, "invalid number") };
        },
        .float => {
            if (value_before_type_cast.len == 0) {
                if (field_after_type_cast.defaultValue()) |default_value| {
                    return .{ .success = default_value };
                }
                return .{ .failure = .init(error.Required, "required") };
            }
            if (std.fmt.parseFloat(ValueAfterTypeCast, value_before_type_cast)) |value_after_type_cast| {
                return .{ .success = value_after_type_cast };
            } else |err| {
                return .{ .failure = .init(err, "invalid number") };
            }
            return .{ .failure = .init(error.InvalidNumber, "invalid number") };
        },
        .@"enum" => {
            if (value_before_type_cast.len == 0) {
                if (field_after_type_cast.defaultValue()) |default_value| {
                    return .{ .success = default_value };
                }
                return .{ .failure = .init(error.Required, "required") };
            }
            if (std.meta.stringToEnum(ValueAfterTypeCast, value_before_type_cast)) |value_after_type_cast| {
                return .{ .success = value_after_type_cast };
            } else {
                return .{ .failure = .init(error.InvalidFormat, "invalid enum") };
            }
        },
        else => {
            return .{ .success = value_before_type_cast };
        },
    }
}

fn UpdateResult(comptime ChangeSet: type, comptime relation: type) type {
    return union(enum) {
        success: relationResultType(relation),
        failure: struct {
            record: relationResultType(relation),
            errors: validation.RecordErrors(ChangeSet),
        },
    };
}

pub fn update(
    self: *const @This(),
    comptime relation: type,
    record: relationResultType(relation),
    change_set: anytype,
) !UpdateResult(@TypeOf(change_set), relation) {
    const ChangeSet = @TypeOf(change_set);
    var errors: validation.RecordErrors(ChangeSet) = .init(self.allocator);
    const change_set_after_type_cast = try self.typeCastedChangeSet(relation, change_set, &errors) orelse return .{ .failure = .{ .record = record, .errors = errors } };

    var updated_record: relationResultType(relation) = undefined;
    inline for (@typeInfo(@TypeOf(record.attributes)).@"struct".fields) |field| {
        @field(updated_record.attributes, field.name) = if (@hasField(@TypeOf(change_set_after_type_cast), field.name)) @field(change_set_after_type_cast, field.name) else @field(record.attributes, field.name);
    }

    if (std.meta.hasFn(relation, "validate")) {
        var change_set_after_type_cast_errors: validation.RecordErrors(@TypeOf(updated_record.attributes)) = .init(self.allocator);
        try relation.validate(updated_record.attributes, &change_set_after_type_cast_errors);
        if (change_set_after_type_cast_errors.isInvalid()) {
            for (change_set_after_type_cast_errors.base_errors.items) |base_error_after_type_cast| {
                try errors.addBaseError(base_error_after_type_cast);
            }
            const ChangeSetField = @TypeOf(errors).Field;
            const ChangeSetAfterTypeCastField = @TypeOf(change_set_after_type_cast_errors).Field;
            for (std.meta.fieldNames(ChangeSetAfterTypeCastField)) |field_name| {
                const change_set_after_type_cast_field = std.meta.stringToEnum(ChangeSetAfterTypeCastField, field_name).?;
                for (change_set_after_type_cast_errors.field_errors.get(change_set_after_type_cast_field).items) |field_error| {
                    if (std.meta.stringToEnum(ChangeSetField, field_name)) |change_set_field| {
                        try errors.addFieldError(change_set_field, field_error);
                    } else {
                        const updated_description = try std.fmt.allocPrint(self.allocator, "{s}: {s}", .{ field_name, field_error.description });
                        try errors.addBaseError(.init(field_error.err, updated_description));
                    }
                }
            }
            return .{ .failure = .{ .errors = errors, .record = updated_record } };
        }
    }

    const sql_update = try typeCastedChangeSetToUpdate(
        self,
        relation,
        record.attributes.id,
        change_set_after_type_cast,
    );

    if (self.conn.rowOpts(
        @TypeOf(sql_update).toSql(),
        sql_update.params(),
        .{ .allocator = self.allocator },
    )) |opt_row| {
        if (opt_row == null) return error.UnknownInsertError;
        var row = opt_row.?;
        const result: relationResultType(relation) = .{ .attributes = try self.rowToAttributes(relation, &row) };
        row.deinit() catch {};
        return .{ .success = result };
    } else |err| {
        if (err == error.PG) {
            if (self.conn.err) |pg_err| {
                try errors.addBaseError(.init(err, pg_err.message));
                return .{ .failure = .{ .errors = errors, .record = updated_record } };
            }
        }

        try errors.addBaseError(.init(err, "unknown error"));
        return .{ .failure = .{ .errors = errors, .record = updated_record } };
    }
}

fn UpdateFromRelation(comptime relation: type, comptime ChangeSet: type) type {
    @setEvalBranchQuota(1000000);

    return sql.Update(.{
        .into = .table(inflector.relationNameFromType(relation)),
        .ChangeSet = ChangeSetAfterDbCast(relation, ChangeSet),
        .Where = sql.where.FromParams(struct { id: primaryKeyType(relation) }),
        .Returning = OutputListFromRelation(relation),
    });
}

fn typeCastedChangeSetToUpdate(self: *const @This(), comptime relation: type, id: primaryKeyType(relation), change_set: anytype) !UpdateFromRelation(relation, @TypeOf(change_set)) {
    @setEvalBranchQuota(1000000);

    return .{
        .change_set = try changeSetAfterDbCast(self, relation, change_set),
        .where = .{ .expression = .{ .params = .{id} } },
        .returning = outputListFromRelation(relation),
    };
}

fn ChangeSetAfterDbCast(relation: type, ChangeSet: type) type {
    @setEvalBranchQuota(1000000);
    const to_db_casts = if (@hasDecl(relation, "to_db_casts")) relation.to_db_casts else struct {};
    const change_set_fields = std.meta.fields(ChangeSet);
    var fields: [change_set_fields.len]std.builtin.Type.StructField = undefined;
    field: for (change_set_fields, 0..) |change_set_field, index| {
        if (std.meta.hasFn(to_db_casts, change_set_field.name)) {
            fields[index] = .{
                .name = change_set_field.name,
                .type = @typeInfo(@typeInfo(@TypeOf(@field(to_db_casts, change_set_field.name))).@"fn".return_type.?).error_union.payload,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = change_set_field.alignment,
            };
            continue :field;
        }

        switch (@typeInfo(change_set_field.type)) {
            .@"struct" => {
                if (std.meta.hasMethod(change_set_field.type, "castToDb")) {
                    fields[index] = .{
                        .name = change_set_field.name,
                        .type = @typeInfo(@typeInfo(@TypeOf(change_set_field.type.castToDb)).@"fn".return_type.?).error_union.payload,
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = change_set_field.alignment,
                    };
                    continue :field;
                }
            },
            .optional => |optional| {
                if (std.meta.hasMethod(optional.child, "castToDb")) {
                    fields[index] = .{
                        .name = change_set_field.name,
                        .type = ?@typeInfo(@typeInfo(@TypeOf(optional.child.castToDb)).@"fn".return_type.?).error_union.payload,
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = change_set_field.alignment,
                    };
                    continue :field;
                }
            },
            else => {},
        }

        fields[index] = change_set_field;
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
    const to_db_casts = if (@hasDecl(relation, "to_db_casts")) relation.to_db_casts else struct {};
    field: inline for (std.meta.fields(@TypeOf(change_set))) |field| {
        if (std.meta.hasFn(to_db_casts, field.name)) {
            @field(result, field.name) = try @field(to_db_casts, field.name)(@field(change_set, field.name), self);
            continue :field;
        }

        switch (@typeInfo(field.type)) {
            .@"struct" => {
                if (std.meta.hasMethod(field.type, "castToDb")) {
                    @field(result, field.name) = try @field(change_set, field.name).castToDb(self);
                    continue :field;
                }
            },
            .optional => |optional| {
                if (std.meta.hasMethod(optional.child, "castToDb")) {
                    if (@field(change_set, field.name)) |present_value| {
                        @field(result, field.name) = try present_value.castToDb(self);
                    } else {
                        @field(result, field.name) = null;
                    }
                    continue :field;
                }
            },
            else => {},
        }

        @field(result, field.name) = @field(change_set, field.name);
    }
    return result;
}

fn RelationAttributesBeforeDbCast(relation: type) type {
    const from_db_casts = if (@hasDecl(relation, "from_db_casts")) relation.from_db_casts else struct {};
    const relation_fields = std.meta.fields(relation.Attributes);
    var fields: [relation_fields.len]std.builtin.Type.StructField = undefined;
    field: for (relation_fields, 0..) |relation_field, index| {
        if (std.meta.hasFn(from_db_casts, relation_field.name)) {
            fields[index] = .{
                .name = relation_field.name,
                .type = @typeInfo(@TypeOf(@field(relation.from_db_casts, relation_field.name))).@"fn".params[0].type.?,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = relation_field.alignment,
            };
            continue :field;
        }

        switch (@typeInfo(relation_field.type)) {
            .@"struct" => {
                if (std.meta.hasFn(relation_field.type, "castFromDb")) {
                    fields[index] = .{
                        .name = relation_field.name,
                        .type = @typeInfo(@TypeOf(relation_field.type.castFromDb)).@"fn".params[0].type.?,
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = relation_field.alignment,
                    };
                    continue :field;
                }
            },
            .optional => |optional| {
                if (std.meta.hasFn(optional.child, "castFromDb")) {
                    fields[index] = .{
                        .name = relation_field.name,
                        .type = ?@typeInfo(@TypeOf(optional.child.castFromDb)).@"fn".params[0].type.?,
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = relation_field.alignment,
                    };
                    continue :field;
                }
            },
            else => {},
        }

        fields[index] = relation_field;
    }

    return @Type(.{ .@"struct" = .{
        .decls = &[_]std.builtin.Type.Declaration{},
        .fields = &fields,
        .is_tuple = false,
        .layout = .auto,
    } });
}

fn rowToAttributes(self: *const @This(), comptime relation: type, row: anytype) !relation.Attributes {
    var attributes: relation.Attributes = undefined;
    const AttributesBeforeDbCast = RelationAttributesBeforeDbCast(relation);
    const attributes_before_db_cast = try row.to(AttributesBeforeDbCast, .{ .dupe = true, .allocator = self.allocator });
    const from_db_casts = if (@hasDecl(relation, "from_db_casts")) relation.from_db_casts else struct {};
    field: inline for (std.meta.fields(@TypeOf(attributes))) |field| {
        if (std.meta.hasFn(from_db_casts, field.name)) {
            @field(attributes, field.name) = try @field(from_db_casts, field.name)(@field(attributes_before_db_cast, field.name), self);
            continue :field;
        }

        switch (@typeInfo(field.type)) {
            .@"struct" => {
                if (std.meta.hasFn(field.type, "castFromDb")) {
                    @field(attributes, field.name) = try field.type.castFromDb(@field(attributes_before_db_cast, field.name), self);
                    continue :field;
                }
            },
            .optional => |optional| {
                if (std.meta.hasFn(optional.child, "castFromDb")) {
                    if (@field(attributes_before_db_cast, field.name)) |present_attribute| {
                        @field(attributes, field.name) = try optional.child.castFromDb(present_attribute, self);
                    } else {
                        @field(attributes, field.name) = null;
                    }
                    continue :field;
                }
            },
            else => {},
        }

        @field(attributes, field.name) = @field(attributes_before_db_cast, field.name);
    }
    return attributes;
}

pub fn beginTransaction(self: *@This()) !*const Transaction {
    if (self.transactions.first) |node| {
        const current_transaction: *Transaction = @alignCast(@fieldParentPtr("node", node));
        switch (current_transaction.db_transaction) {
            .transaction => {
                return try self.beginSavepointTransaction(1);
            },
            .savepoint => |savepoint| {
                return try self.beginSavepointTransaction(savepoint.index + 1);
            },
        }
    } else {
        try self.conn.begin();
        return try self.pushTransaction(.transaction);
    }
}

fn beginSavepointTransaction(self: *@This(), new_savepoint_index: usize) !*const Transaction {
    const new_savepoint_name = try std.fmt.allocPrint(self.allocator, "repo_{*}_{d}", .{ self, new_savepoint_index + 1 });
    const savepoint_statement = try std.fmt.allocPrint(self.allocator, "SAVEPOINT {s}", .{new_savepoint_name});
    defer self.allocator.free(savepoint_statement);

    _ = try self.conn.execOpts(savepoint_statement, .{}, .{ .allocator = self.allocator });

    return try self.pushTransaction(.{ .savepoint = .{ .index = new_savepoint_index, .name = new_savepoint_name } });
}

fn pushTransaction(self: *@This(), db_transaction: DbTransaction) !*const Transaction {
    const new_transaction = try self.allocator.create(Transaction);
    new_transaction.db_transaction = db_transaction;
    self.transactions.prepend(&new_transaction.node);
    return new_transaction;
}

pub fn commitTransaction(self: *@This(), transaction: *const Transaction) !void {
    switch (transaction.db_transaction) {
        .savepoint => |savepoint| {
            const release_savepoint_statement = try std.fmt.allocPrint(self.allocator, "RELEASE SAVEPOINT {s}", .{savepoint.name});
            defer self.allocator.free(release_savepoint_statement);
            _ = try self.conn.execOpts(release_savepoint_statement, .{}, .{ .allocator = self.allocator });
        },
        .transaction => {
            _ = try self.conn.commit();
        },
    }
    self.deinitCompletedTransactions(transaction);
}

pub fn rollbackTransaction(self: *@This(), transaction: *const Transaction) !void {
    switch (transaction.db_transaction) {
        .savepoint => |savepoint| {
            const rollback_to_savepoint_statement = try std.fmt.allocPrint(self.allocator, "ROLLBACK TO SAVEPOINT {s}", .{savepoint.name});
            defer self.allocator.free(rollback_to_savepoint_statement);
            _ = try self.conn.execOpts(rollback_to_savepoint_statement, .{}, .{ .allocator = self.allocator });
        },
        .transaction => {
            _ = try self.conn.rollback();
        },
    }
    self.deinitCompletedTransactions(transaction);
}

fn deinitCompletedTransactions(self: *@This(), completed_transaction: *const Transaction) void {
    while (self.transactions.popFirst()) |node| {
        const transaction: *const Transaction = @alignCast(@fieldParentPtr("node", node));
        switch (transaction.db_transaction) {
            .savepoint => |savepoint| {
                self.allocator.free(savepoint.name);
            },
            else => {},
        }
        self.allocator.destroy(transaction);
        if (transaction == completed_transaction) {
            return;
        }
    }
    unreachable;
}
