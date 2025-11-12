const std = @import("std");

fn writeUrlFormEncodedPath(writer: *std.Io.Writer, path: []const []const u8) !void {
    for (path, 0..) |segment, index| {
        if (index > 0) {
            try writer.print("[{s}]", .{segment});
        } else {
            try writer.writeAll(segment);
        }
    }
}

fn urlFormEncodedPathCount(path: []const []const u8) usize {
    var discarding_writer = std.Io.Writer.Discarding.init(&.{});
    writeUrlFormEncodedPath(&discarding_writer.writer, path) catch unreachable;
    return discarding_writer.count;
}

fn comptimeUrlFormEncodedPath(comptime path: []const []const u8) [:0]const u8 {
    const url_form_encoded_path = comptime url_form_encoded_path: {
        var buffer: [urlFormEncodedPathCount(path):0]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);

        writeUrlFormEncodedPath(&writer, path) catch unreachable;

        buffer[buffer.len] = 0;
        const result = buffer;
        break :url_form_encoded_path &result;
    };
    return url_form_encoded_path;
}

pub fn parse(T: type, url_form_encoded_data: anytype) !T {
    return parseInternal(T, url_form_encoded_data, &[_][]const u8{}) catch |err| switch (err) {
        error.MissingField => error.InvalidUrlFormEncodedData,
        else => return err,
    };
}

inline fn parseInternal(T: type, url_form_encoded_data: anytype, comptime prefix: []const []const u8) !T {
    switch (@typeInfo(T)) {
        .@"struct" => |@"struct"| {
            var result: T = undefined;
            inline for (@"struct".fields) |field| {
                @field(result, field.name) = parseInternal(
                    field.type,
                    url_form_encoded_data,
                    prefix ++ .{field.name},
                ) catch |err| switch (err) {
                    error.MissingField => if (field.defaultValue()) |default_value| default_value else return err,
                    else => return err,
                };
            }
            return result;
        },
        .optional => |optional| {
            switch (@typeInfo(optional.child)) {
                .@"struct" => |@"struct"| {
                    var has_any_field = false;
                    inline for (@"struct".fields) |field| fields: {
                        const path = comptimeUrlFormEncodedPath(prefix ++ .{field.name});
                        var url_form_encoded_data_iterator = url_form_encoded_data.iterator();
                        while (url_form_encoded_data_iterator.next()) |key_value| {
                            if (std.mem.startsWith(u8, key_value.key, path)) {
                                has_any_field = true;
                                break :fields;
                            }
                        }
                    }
                    if (!has_any_field) {
                        return null;
                    }
                    return try parseInternal(optional.child, url_form_encoded_data, prefix);
                },
                else => {
                    return url_form_encoded_data.get(comptimeUrlFormEncodedPath(prefix));
                },
            }
        },
        else => {
            return url_form_encoded_data.get(comptimeUrlFormEncodedPath(prefix)) orelse return error.MissingField;
        },
    }
}
