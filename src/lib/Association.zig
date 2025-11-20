const std = @import("std");

const pg = @import("pg");

const inflector = @import("inflector.zig");
const Repo = @import("Repo.zig");
const sql = @import("sql.zig");

relation: type,
name: []const u8,
type: enum {
    has_many,
    belongs_to,
},

pub fn belongsTo(comptime relation: type) @This() {
    return .{
        .relation = relation,
        .name = inflector.comptimeSingularize(inflector.relationNameFromType(relation)),
        .type = .belongs_to,
    };
}

pub fn hasMany(comptime relation: type) @This() {
    return .{
        .relation = relation,
        .name = inflector.relationNameFromType(relation),
        .type = .has_many,
    };
}

fn PreloadedFromRelationWhere(comptime self: @This(), comptime relation: type) type {
    switch (self.type) {
        .belongs_to => {
            return sql.Where(sql.ParameterizedSnippet(
                "id = ANY (?)",
                struct { pg.Binary },
            ));
        },
        .has_many => {
            return sql.Where(sql.ParameterizedSnippet(
                inflector.comptimeSingularize(inflector.relationNameFromType(relation)) ++ "_id = ANY (?)",
                struct { pg.Binary },
            ));
        },
    }
}

const UuidArray = struct {
    uuids: []const []const u8,

    pub fn castToDb(self: *const @This(), repo: *const Repo) !pg.Binary {
        const buffer = try repo.allocator.alloc(u8, 20 + 20 * self.uuids.len);
        var writer: std.Io.Writer = .fixed(buffer);

        writer.writeInt(i32, 1, .big) catch unreachable; // dimensions
        writer.writeInt(i32, 0, .big) catch unreachable; // bitmask of null
        writer.writeInt(i32, 2950, .big) catch unreachable; // oid for UUID
        writer.writeInt(i32, @intCast(self.uuids.len), .big) catch unreachable; // number of UUIDs
        writer.writeInt(i32, 1, .big) catch unreachable; // lower bound of this dimension

        for (self.uuids) |uuid| {
            writer.writeInt(i32, 16, .big) catch unreachable;
            writer.writeAll(uuid) catch unreachable;
        }

        return .{ .data = buffer };
    }
};

pub fn preloadedFromRelationWhere(comptime self: @This(), comptime relation: type, relation_records: anytype, repo: *const Repo) !PreloadedFromRelationWhere(self, relation) {
    switch (self.type) {
        .belongs_to => {
            var associated_ids_array_list: std.ArrayList([]const u8) = .{};
            const id_field_name = inflector.comptimeSingularize(inflector.relationNameFromType(self.relation)) ++ "_id";
            for (relation_records) |relation_record| {
                try associated_ids_array_list.append(repo.allocator, @field(relation_record.attributes, id_field_name));
            }
            const associated_ids = try associated_ids_array_list.toOwnedSlice(repo.allocator);
            defer repo.allocator.free(associated_ids);
            const uuid_array: UuidArray = .{ .uuids = associated_ids };
            return .{ .expression = .{ .params = .{try uuid_array.castToDb(repo)} } };
        },
        else => {
            var asosciated_ids_array: std.ArrayList([]const u8) = .{};
            for (relation_records) |relation_record| {
                try asosciated_ids_array.append(repo.allocator, relation_record.attributes.id);
            }
            const associated_ids = try asosciated_ids_array.toOwnedSlice(repo.allocator);
            defer repo.allocator.free(associated_ids);
            const uuid_array: UuidArray = .{ .uuids = associated_ids };
            return .{ .expression = .{ .params = .{try uuid_array.castToDb(repo)} } };
        },
    }
}

pub fn populate(
    comptime self: @This(),
    comptime relation: type,
    relation_records: anytype,
    association_records: anytype,
    repo: *const Repo,
) !void {
    switch (self.type) {
        .belongs_to => {
            const id_field_name = inflector.comptimeSingularize(inflector.relationNameFromType(self.relation)) ++ "_id";
            var associated_records_by_id: std.StringHashMapUnmanaged(*@typeInfo(@TypeOf(association_records)).pointer.child) = .{};
            for (association_records) |*association_record| {
                try associated_records_by_id.put(repo.allocator, association_record.attributes.id, association_record);
            }
            for (relation_records) |*relation_record| {
                @field(relation_record.associations, self.name) = associated_records_by_id.get(@field(relation_record.attributes, id_field_name)).?;
            }
        },
        .has_many => {
            const id_field_name = inflector.comptimeSingularize(inflector.relationNameFromType(relation)) ++ "_id";
            var associated_records_arrays_by_id: std.StringHashMapUnmanaged(std.ArrayList(*@typeInfo(@TypeOf(association_records)).pointer.child)) = .{};
            defer associated_records_arrays_by_id.deinit(repo.allocator);
            for (association_records) |*association_record| {
                const id = @field(association_record.attributes, id_field_name);
                if (!associated_records_arrays_by_id.contains(id)) {
                    try associated_records_arrays_by_id.put(repo.allocator, id, .{});
                }
                var associated_records = associated_records_arrays_by_id.getPtr(id).?;
                try associated_records.append(repo.allocator, association_record);
            }
            for (relation_records) |*relation_record| {
                if (associated_records_arrays_by_id.getPtr(relation_record.attributes.id)) |associated_records_array| {
                    @field(relation_record.associations, self.name) = try associated_records_array.toOwnedSlice(repo.allocator);
                } else {
                    @field(relation_record.associations, self.name) = &[_]@typeInfo(@TypeOf(@field(relation_record.associations, self.name))).pointer.child{};
                }
            }
        },
    }
}
