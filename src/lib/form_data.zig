const std = @import("std");

fn formDataPathCount(path: []const []const u8) usize {
    var count: usize = 0;
    for (path, 0..) |segment, index| {
        if (index > 0) {
            count += 2;
        }
        count += segment.len;
    }
    return count;
}

fn writeFormDataPath(writer: *std.Io.Writer, path: []const []const u8) std.Io.Writer.Error!void {
    for (path, 0..) |segment, index| {
        if (index > 0) {
            try writer.print("[{s}]", .{segment});
        } else {
            try writer.writeAll(segment);
        }
    }
}

fn comptimeFormDataPath(comptime path: []const []const u8) [formDataPathCount(path):0]u8 {
    var buffer: [formDataPathCount(path):0]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    writeFormDataPath(&writer, path) catch unreachable;

    buffer[buffer.len] = 0;
    return buffer;
}

pub const empty_prefix: [][]const u8 = &[_][]const u8{};

pub fn parse(T: type, form_data: anytype, comptime prefix: []const []const u8) !T {
    switch (@typeInfo(T)) {
        .@"struct" => |@"struct"| {
            var result: T = undefined;
            inline for (@"struct".fields) |field| {
                @field(result, field.name) = try parse(
                    field.type,
                    form_data,
                    prefix ++ .{field.name},
                );
            }
            return result;
        },
        .optional => |optional| {
            switch (@typeInfo(optional.child)) {
                .@"struct" => |@"struct"| {
                    var has_any_field = false;
                    for (@"struct".fields) |field| fields: {
                        const path = &comptimeFormDataPath(prefix ++ .{field.name});
                        for (form_data.keys) |key| {
                            if (std.mem.startsWith(u8, key, path)) {
                                has_any_field = true;
                                break :fields;
                            }
                        }
                    }
                    if (!has_any_field) {
                        return null;
                    }
                    return try parse(optional.child, form_data, prefix);
                },
                else => {
                    return form_data.get(&comptimeFormDataPath(prefix));
                },
            }
        },
        else => {
            return form_data.get(&comptimeFormDataPath(prefix)) orelse return error.MissingField;
        },
    }
}
