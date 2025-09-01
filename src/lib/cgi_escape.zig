const std = @import("std");

pub fn writeEscapedHtml(writer: *std.Io.Writer, unsafe_text: []const u8) !void {
    var utf8 = (try std.unicode.Utf8View.init(unsafe_text)).iterator();
    while (utf8.nextCodepoint()) |codepoint| {
        switch (codepoint) {
            '\'' => try writer.writeAll("&#39;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.printUnicodeCodepoint(codepoint),
        }
    }
}

pub fn writeEscapedUriComponent(writer: *std.Io.Writer, unsafe_text: []const u8) std.Io.Writer.Error!void {
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

pub fn writeUnescapedUriComponent(writer: *std.Io.Writer, escaped_uri_component: []const u8) (UnescapeUriComponentError || std.Io.Writer.Error)!void {
    var iterator = EscapedUriComponentIterator.init(escaped_uri_component);
    while (try iterator.next()) |byte| {
        try writer.writeByte(byte);
    }
}

pub fn unescapeUriComponentAlloc(allocator: std.mem.Allocator, escaped_uri_component: []const u8) ![]const u8 {
    const size = try countUnescapedUriComponent(escaped_uri_component);
    const buf = try allocator.alloc(u8, size);
    var writer = std.Io.Writer.fixed(buf);
    try writeUnescapedUriComponent(&writer, escaped_uri_component);
    return buf;
}

pub fn writeEscapedFormEncodedComponent(writer: *std.Io.Writer, unsafe_text: []const u8) std.Io.Writer.Error!void {
    for (unsafe_text) |character| {
        switch (character) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '.', '-', '~' => try writer.writeByte(character),
            ' ' => try writer.writeByte('+'),
            else => try std.fmt.format(writer, "%{X:0>2}", .{character}),
        }
    }
}

pub const EscapedHtmlAttributeWriter = struct {
    out: *std.Io.Writer,
    interface: std.Io.Writer,

    pub fn init(out: *std.Io.Writer) @This() {
        return .{
            .out = out,
            .interface = .{
                .vtable = &.{
                    .drain = @This().drain,
                },
                .buffer = &.{},
            },
        };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
        const self: *const @This() = @alignCast(@fieldParentPtr("interface", w));
        var drained: usize = 0;
        for (data[0 .. data.len - 1]) |datum| {
            for (datum) |c| {
                try self.writeEscapedByte(c);
                drained += 1;
            }
        }
        for (0..splat) |_| {
            for (data[data.len - 1]) |c| {
                try self.writeEscapedByte(c);
                drained += 1;
            }
        }
        return drained;
    }

    fn writeEscapedByte(self: *const @This(), unescaped_byte: u8) !void {
        switch (unescaped_byte) {
            '"' => try self.out.writeAll("&quot;"),
            else => try self.out.writeByte(unescaped_byte),
        }
    }
};

pub fn writeEscapedHtmlAttribute(writer: *std.Io.Writer, unsafe_text: []const u8) std.Io.Writer.Error!void {
    var escaped_writer: EscapedHtmlAttributeWriter = .init(writer);
    try escaped_writer.interface.writeAll(unsafe_text);
    try escaped_writer.interface.flush();
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
