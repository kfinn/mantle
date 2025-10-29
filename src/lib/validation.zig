const std = @import("std");

pub const Error = struct {
    err: anyerror,
    description: []const u8,

    pub fn init(err: anyerror, description: []const u8) @This() {
        return .{ .err = err, .description = description };
    }

    pub fn format(self: *const @This(), writer: *std.Io.Writer) !void {
        try writer.print("{s} ({s})", .{ self.description, @tagName(self.err) });
    }
};

pub fn RecordErrors(Record: type) type {
    switch (@typeInfo(Record)) {
        .pointer => |pointer| {
            return Errors(std.meta.FieldEnum(pointer.child));
        },
        .@"struct" => {
            return Errors(std.meta.FieldEnum(Record));
        },
        else => {
            @compileError("unable to build errors for type " ++ @typeName(Record));
        },
    }
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
                field_errors.set(entry.key, .{});
            }

            return .{
                .allocator = allocator,
                .base_errors = .{},
                .field_errors = field_errors,
            };
        }

        pub fn deinit(self: *@This()) void {
            self.base_errors.deinit(self.allocator);
            for (self.field_errors.values) |*field_errors| {
                field_errors.deinit(self.allocator);
            }
        }

        pub fn addBaseError(self: *@This(), validation_error: Error) !void {
            try self.base_errors.append(self.allocator, validation_error);
        }

        pub fn addFieldError(self: *@This(), field: Field, validation_error: Error) !void {
            try self.field_errors.getPtr(field).append(self.allocator, validation_error);
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

        pub fn format(self: *const @This(), writer: std.Io.Writer) !void {
            for (self.base_errors.items) |base_error| {
                writer.print("error: {f}\n", .{base_error});
            }
            for (self.field_errors.values, 0..) |field_errors, field_index| {
                const field = @TypeOf(self.field_errors).Indexer.keyForIndex(field_index);
                for (field_errors.items) |field_error| {
                    std.log.err("{s} error: {f}", .{ @tagName(field), field_error });
                }
            }
        }
    };
}

pub fn validatePresence(record: anytype, comptime fields: []const std.meta.FieldEnum(@TypeOf(record)), errors: *RecordErrors(@TypeOf(record))) !void {
    fields: inline for (fields) |field| {
        const field_type = std.meta.fieldInfo(@TypeOf(record), field).type;
        const field_type_info = @typeInfo(field_type);

        const possibly_opt_value = @field(record, @tagName(field));
        const value = unwrap_optional: switch (field_type_info) {
            .optional => {
                if (possibly_opt_value == null) {
                    try errors.addFieldError(field, .init(error.Required, "required"));
                    continue :fields;
                }
                break :unwrap_optional possibly_opt_value.?;
            },
            else => break :unwrap_optional possibly_opt_value,
        };
        const value_type_info = @typeInfo(@TypeOf(value));
        switch (value_type_info) {
            .pointer => |pointer| {
                if (pointer.size == .slice) {
                    if (value.len == 0) {
                        try errors.addFieldError(field, .init(error.Required, "required"));
                    }
                    continue :fields;
                }
            },
            else => {},
        }
        @compileError("Cannot validate presence of type: " ++ @typeName(field_type));
    }
}
