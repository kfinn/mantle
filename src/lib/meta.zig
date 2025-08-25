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
