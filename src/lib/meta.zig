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
