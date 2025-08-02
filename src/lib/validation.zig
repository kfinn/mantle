const std = @import("std");

pub const Error = struct {
    err: anyerror,
    description: []const u8,

    pub fn init(err: anyerror, description: []const u8) @This() {
        return .{ .err = err, .description = description };
    }
};

pub fn RecordErrors(Record: type) type {
    return Errors(std.meta.FieldEnum(Record));
}

pub fn Errors(FieldParam: type) type {
    return struct {
        allocator: std.mem.Allocator,
        base_errors: std.ArrayList(Error),
        field_errors: std.EnumArray(Field, std.ArrayList(Error)),

        pub fn init(allocator: std.mem.Allocator) @This() {
            var field_errors = std.EnumArray(Field, std.ArrayList(Error)).initUndefined();
            var field_errors_iterator = field_errors.iterator();
            while (field_errors_iterator.next()) |entry| {
                field_errors.set(entry.key, .init(allocator));
            }

            return .{
                .allocator = allocator,
                .base_errors = .init(allocator),
                .field_errors = field_errors,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.base_errors_builder.deinit();
            for (self.field_errors_builder.values) |field_errors| {
                field_errors.deinit();
            }
        }
        pub fn addBaseError(self: *@This(), validation_error: Error) !void {
            try self.base_errors.append(validation_error);
        }

        pub fn addFieldError(self: *@This(), field: Field, validation_error: Error) !void {
            try self.field_errors.getPtr(field).append(validation_error);
        }

        pub fn isInvalid(self: *const @This()) bool {
            return !self.isValid();
        }

        pub fn isValid(self: *const @This()) bool {
            for (self.field_errors.values) |field_validation_errors| {
                if (field_validation_errors.items.len > 0) {
                    return false;
                }
            }
            return self.base_errors.items.len == 0;
        }

        pub const Field = FieldParam;
    };
}
