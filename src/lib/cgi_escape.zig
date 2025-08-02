const std = @import("std");

pub fn writeEscapedHtml(writer: anytype, unsafe_text: []const u8) @TypeOf(writer).Error!void {
    for (unsafe_text) |character| {
        switch (character) {
            '\'' => try writer.writeAll("&#39;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(character),
        }
    }
}

pub fn writeEscapedUriComponent(writer: anytype, unsafe_text: []const u8) @TypeOf(writer).Error!void {
    for (unsafe_text) |character| {
        switch (character) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '-', '~' => try writer.writeByte(character),
            else => try std.fmt.format(writer, "%{X:0>2}", .{character}),
        }
    }
}

const UnescapeUriComponentError = error{InvalidEscape};

const EscapedUriComponentIterator = struct {
    escaped_uri_component: []const u8,
    index: usize = 0,

    fn init(escaped_uri_component: []const u8) @This() {
        return .{ .escaped_uri_component = escaped_uri_component };
    }

    fn next(self: *@This()) UnescapeUriComponentError!?u8 {
        if (self.index >= self.escaped_uri_component.len) {
            return null;
        }

        if (self.escaped_uri_component[self.index] == '%') {
            if (self.index + 2 < self.escaped_uri_component.len and
                std.ascii.isHex(self.escaped_uri_component[self.index + 1]) and
                std.ascii.isHex(self.escaped_uri_component[self.index + 2]))
            {
                const unescaped_character = std.fmt.parseInt(u8, self.escaped_uri_component[self.index + 1 .. self.index + 3], 16) catch return UnescapeUriComponentError.InvalidEscape;
                if (std.ascii.isAscii(unescaped_character)) {
                    self.index += 3;
                    return unescaped_character;
                }
            }
            return UnescapeUriComponentError.InvalidEscape;
        }
        const character = self.escaped_uri_component[self.index];
        self.index += 1;
        return character;
    }
};

fn countUnescapedUriComponent(escaped_uri_component: []const u8) UnescapeUriComponentError!usize {
    var iterator = EscapedUriComponentIterator.init(escaped_uri_component);
    var count: usize = 0;
    while (try iterator.next()) |_| {
        count += 1;
    }
    return count;
}

pub fn writeUnescapedUriComponent(writer: anytype, escaped_uri_component: []const u8) (UnescapeUriComponentError || @TypeOf(writer).Error)!void {
    var iterator = EscapedUriComponentIterator.init(escaped_uri_component);
    while (try iterator.next()) |byte| {
        try writer.writeByte(byte);
    }
}

pub fn unescapeUriComponentAlloc(allocator: std.mem.Allocator, escaped_uri_component: []const u8) ![]const u8 {
    const size = try countUnescapedUriComponent(escaped_uri_component);
    const buf = try allocator.alloc(u8, size);
    var fbs = std.io.fixedBufferStream(buf);
    try writeUnescapedUriComponent(fbs.writer().any(), escaped_uri_component);
    return buf;
}

pub fn writeEscapedFormEncodedComponent(writer: anytype, unsafe_text: []const u8) @TypeOf(writer).Error!void {
    for (unsafe_text) |character| {
        switch (character) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '-', '~' => try writer.writeByte(character),
            ' ' => try writer.writeByte('+'),
            else => try std.fmt.format(writer, "%{X:0>2}", .{character}),
        }
    }
}

pub fn writeEscapedHtmlAttribute(writer: anytype, unsafe_text: []const u8) @TypeOf(writer).Error!void {
    for (unsafe_text) |character| {
        switch (character) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            else => try writer.writeByte(character),
        }
    }
}

test writeEscapedHtml {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    try writeEscapedHtml(buf.writer(), "<div style=\"position: absolute; top: 0;\">&'</div>");
    const actual = try buf.toOwnedSlice();
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("&lt;div style=&quot;position: absolute; top: 0;&quot;&gt;&amp;&#39;&lt;/div&gt;", actual);
}

test writeEscapedUriComponent {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    try writeEscapedUriComponent(buf.writer(), "'Stop!' said Fred");
    const actual = try buf.toOwnedSlice();
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("%27Stop%21%27%20said%20Fred", actual);
}

test writeEscapedFormEncodedComponent {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    try writeEscapedFormEncodedComponent(buf.writer(), "'Stop!' said Fred");
    const actual = try buf.toOwnedSlice();
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("%27Stop%21%27+said+Fred", actual);
}

test writeEscapedHtmlAttribute {
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    try writeEscapedHtmlAttribute(buf.writer(), "robert\"><script>window.alert('boo!')</script>");
    const actual = try buf.toOwnedSlice();
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("robert\\\"><script>window.alert('boo!')</script>", actual);
}
