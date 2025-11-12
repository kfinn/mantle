const std = @import("std");

pub fn TupleFromStruct(comptime Struct: type) type {
    const fields = std.meta.fields(Struct);
    var field_types: [fields.len]type = undefined;
    inline for (fields, 0..) |field, index| {
        field_types[index] = field.type;
    }
    return std.meta.Tuple(&field_types);
}

pub fn structToTuple(@"struct": anytype) TupleFromStruct(@TypeOf(@"struct")) {
    var tuple: TupleFromStruct(@TypeOf(@"struct")) = undefined;
    inline for (comptime std.meta.fieldNames(@TypeOf(@"struct")), 0..) |field_name, index| {
        tuple[index] = @field(@"struct", field_name);
    }
    return tuple;
}

pub fn MergedTuples(comptime Lhs: type, comptime Rhs: type) type {
    const lhs_fields = @typeInfo(Lhs).@"struct".fields;
    const rhs_fields = @typeInfo(Rhs).@"struct".fields;
    var fields: [lhs_fields.len + rhs_fields.len]std.builtin.Type.StructField = undefined;

    inline for (lhs_fields, 0..) |lhs_field, index| {
        fields[index] = .{
            .name = std.fmt.comptimePrint("{d}", .{index}),
            .type = lhs_field.type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = lhs_field.alignment,
        };
    }
    inline for (rhs_fields, 0..) |rhs_field, index| {
        fields[index + lhs_fields.len] = .{
            .name = std.fmt.comptimePrint("{d}", .{index + lhs_fields.len}),
            .type = rhs_field.type,
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = rhs_field.alignment,
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &[_]std.builtin.Type.Declaration{},
        .is_tuple = true,
    } });
}

pub fn mergeTuples(lhs: anytype, rhs: anytype) MergedTuples(@TypeOf(lhs), @TypeOf(rhs)) {
    var result: MergedTuples(@TypeOf(lhs), @TypeOf(rhs)) = undefined;
    inline for (0..lhs.len) |index| {
        result[index] = lhs[index];
    }
    inline for (0..rhs.len) |rhs_index| {
        result[rhs_index + lhs.len] = rhs[rhs_index];
    }

    return result;
}

pub fn FlattenedTuples(comptime Tuples: type) type {
    const flattened_fields_count = comptime flattened_fields_count: {
        var count = 0;
        for (@typeInfo(Tuples).@"struct".fields) |field| {
            count += @typeInfo(field.type).@"struct".fields.len;
        }
        break :flattened_fields_count count;
    };
    const flattened_field_types = comptime flattened_field_types: {
        var types_buf: [flattened_fields_count]type = undefined;
        var next_index = 0;
        for (@typeInfo(Tuples).@"struct".fields) |outer_field| {
            for (@typeInfo(outer_field.type).@"struct".fields) |inner_field| {
                types_buf[next_index] = inner_field.type;
                next_index += 1;
            }
        }
        const types = types_buf;
        break :flattened_field_types &types;
    };
    return std.meta.Tuple(flattened_field_types);
}

fn flattenedTupleIndexFromFields(
    comptime Tuples: type,
    comptime outer_field: std.builtin.Type.StructField,
    comptime inner_field: std.builtin.Type.StructField,
) usize {
    var index = 0;
    for (@typeInfo(Tuples).@"struct".fields) |candidate_outer_field| {
        for (@typeInfo(candidate_outer_field.type).@"struct".fields) |candidate_inner_field| {
            if (std.mem.eql(u8, outer_field.name, candidate_outer_field.name) and std.mem.eql(u8, inner_field.name, candidate_inner_field.name)) {
                return index;
            }
            index += 1;
        }
    }
    return index;
}

pub fn flattenTuples(tuples: anytype) FlattenedTuples(@TypeOf(tuples)) {
    const Tuples = @TypeOf(tuples);
    var result: FlattenedTuples(Tuples) = undefined;
    inline for (@typeInfo(Tuples).@"struct".fields) |outer_field| {
        const tuple = @field(tuples, outer_field.name);
        inline for (@typeInfo(outer_field.type).@"struct".fields) |inner_field| {
            result[comptime flattenedTupleIndexFromFields(Tuples, outer_field, inner_field)] = @field(tuple, inner_field.name);
        }
    }
    return result;
}
