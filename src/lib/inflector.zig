const std = @import("std");

const SuffixInflection = struct {
    singular_suffix: []const u8,
    plural_suffix: []const u8,
};

const suffix_inflections = [_]SuffixInflection{
    .{ .singular_suffix = "y", .plural_suffix = "ies" },
    .{ .singular_suffix = "", .plural_suffix = "s" },
};

fn findSuffixInflectionFromPlural(plural: []const u8) SuffixInflection {
    for (suffix_inflections) |suffix_inflection| {
        if (std.mem.endsWith(u8, plural, suffix_inflection.plural_suffix)) {
            return suffix_inflection;
        }
    }
    return suffix_inflections[suffix_inflections.len - 1];
}

fn findSuffixInflectionFromSingular(singular: []const u8) SuffixInflection {
    for (suffix_inflections) |suffix_inflection| {
        if (std.mem.endsWith(u8, singular, suffix_inflection.singular_suffix)) {
            return suffix_inflection;
        }
    }
    return suffix_inflections[suffix_inflections.len - 1];
}

const IrregularInflection = struct {
    singular: []const u8,
    plural: []const u8,
};

const irregular_inflections = [_]IrregularInflection{
    .{ .singular = "person", .plural = "people" },
    .{ .singular = "man", .plural = "men" },
    .{ .singular = "woman", .plural = "women" },
    .{ .singular = "child", .plural = "children" },
    .{ .singular = "sex", .plural = "sexes" },
    .{ .singular = "move", .plural = "moves" },
    .{ .singular = "zombie", .plural = "zombies" },
    .{ .singular = "octopus", .plural = "octopuses" },
};

fn findIrregularInflectionFromPlural(plural: []const u8) ?IrregularInflection {
    for (irregular_inflections) |irregular_inflection| {
        if (std.mem.eql(u8, plural, irregular_inflection.plural)) {
            return irregular_inflection;
        }
    }
    return null;
}

pub fn singularizeCount(plural: []const u8) usize {
    if (findIrregularInflectionFromPlural(plural)) |irregular_inflection| {
        return irregular_inflection.plural.len;
    }
    const suffix_inflection = findSuffixInflectionFromPlural(plural);
    return plural.len - suffix_inflection.plural_suffix.len + suffix_inflection.singular_suffix.len;
}

pub fn bufSingularize(buf: []u8, plural: []const u8) std.fmt.BufPrintError![]u8 {
    if (findIrregularInflectionFromPlural(plural)) |irregular_inflection| {
        return std.fmt.bufPrint(buf, "{s}", .{irregular_inflection.plural});
    }
    const suffix_inflection = findSuffixInflectionFromPlural(plural);
    return std.fmt.bufPrint(buf, "{s}{s}", .{ plural[0 .. plural.len - suffix_inflection.plural_suffix.len], suffix_inflection.singular_suffix });
}

pub inline fn comptimeSingularize(comptime plural: []const u8) *const [singularizeCount(plural):0]u8 {
    comptime {
        var buf: [singularizeCount(plural):0]u8 = undefined;
        _ = bufSingularize(&buf, plural) catch unreachable;
        buf[buf.len] = 0;
        const final = buf;
        return &final;
    }
}

fn findIrregularInflectionFromSingular(singular: []const u8) ?IrregularInflection {
    for (irregular_inflections) |irregular_inflection| {
        if (std.mem.eql(u8, singular, irregular_inflection.singular)) {
            return irregular_inflection;
        }
    }
    return null;
}

pub fn pluralizeCount(plural: []const u8) usize {
    if (findIrregularInflectionFromPlural(plural)) |irregular_inflection| {
        return irregular_inflection.plural.len;
    }
    const suffix_inflection = findSuffixInflectionFromPlural(plural);
    return plural.len - suffix_inflection.singular_suffix.len + suffix_inflection.plural_suffix.len;
}

pub fn bufPluralize(buf: []u8, plural: []const u8) std.fmt.BufPrintError![]u8 {
    if (findIrregularInflectionFromPlural(plural)) |irregular_inflection| {
        return std.fmt.bufPrint(buf, "{s}", .{irregular_inflection.plural});
    }
    const suffix_inflection = findSuffixInflectionFromPlural(plural);
    return std.fmt.bufPrint(buf, "{s}{s}", .{ plural[0 .. plural.len - suffix_inflection.singular_suffix.len], suffix_inflection.plural_suffix });
}

pub inline fn comptimePluralize(comptime plural: []const u8) *const [pluralizeCount(plural):0]u8 {
    comptime {
        var buf: [pluralizeCount(plural):0]u8 = undefined;
        _ = bufPluralize(&buf, plural) catch unreachable;
        buf[buf.len] = 0;
        const final = buf;
        return &final;
    }
}

const WordIterator = struct {
    const State = enum { acronym, word };

    text: []const u8,
    state: State,
    index: usize,

    fn init(text: []const u8) @This() {
        return .{
            .text = text,
            .state = if (text.len > 1 and std.ascii.isUpper(text[0]) and std.ascii.isUpper(text[1])) .acronym else .word,
            .index = 0,
        };
    }

    fn next(self: *@This()) ?[]const u8 {
        if (self.index >= self.text.len) return null;

        for (self.index + 1..self.text.len) |end_index| {
            switch (self.state) {
                .acronym => {
                    if (std.ascii.isLower(self.text[end_index])) {
                        const result = self.text[self.index..(end_index - 1)];
                        self.index = end_index - 1;
                        self.state = .word;
                        return result;
                    }
                },
                .word => {
                    if (std.ascii.isLower(self.text[end_index - 1]) and std.ascii.isUpper(self.text[end_index])) {
                        const result = self.text[self.index..end_index];
                        self.index = end_index;
                        const next_end_index = end_index + 1;
                        if (next_end_index < self.text.len) {
                            self.state = if (std.ascii.isUpper(self.text[next_end_index])) .acronym else .word;
                        }
                        return result;
                    }
                },
            }
        }

        const result = self.text[self.index..];
        self.index = self.text.len;
        return result;
    }
};

pub fn snakeizeCount(text: []const u8) usize {
    var word_iterator = WordIterator.init(text);
    var words_count = 0;
    while (word_iterator.next()) |_| {
        words_count += 1;
    }
    return text.len + words_count - 1;
}

pub fn bufSnakeize(buf: []u8, text: []const u8) std.fmt.BufPrintError![]u8 {
    var word_iterator = WordIterator.init(text);
    var buf_stream = std.io.fixedBufferStream(buf);
    var buf_writer = buf_stream.writer();
    var requires_underscore = false;
    var bytes_written = 0;
    while (word_iterator.next()) |word| {
        if (requires_underscore) {
            try buf_writer.writeByte('_');
            bytes_written += 1;
        }
        for (word) |c| {
            try buf_writer.writeByte(std.ascii.toLower(c));
            bytes_written += 1;
        }
        requires_underscore = true;
    }
    return buf[0..bytes_written];
}

pub fn comptimeSnakeize(comptime text: []const u8) *const [snakeizeCount(text):0]u8 {
    comptime {
        var buf: [snakeizeCount(text):0]u8 = undefined;
        _ = bufSnakeize(&buf, text) catch unreachable;
        buf[buf.len] = 0;
        const final = buf;
        return &final;
    }
}

pub fn tableizeCount(text: []const u8) usize {
    return text.len + (pluralizeCount(text) - text.len) + (snakeizeCount(text) - text.len);
}

pub fn comptimeTableize(comptime text: []const u8) *const [tableizeCount(text):0]u8 {
    return comptimePluralize(comptimeSnakeize(text));
}

test comptimeTableize {
    try std.testing.expectEqualStrings("users", comptime comptimeTableize("User"));
    try std.testing.expectEqualStrings("user_groups", comptime comptimeTableize("userGroup"));
    try std.testing.expectEqualStrings("user_groups", comptime comptimeTableize("UserGroup"));
    try std.testing.expectEqualStrings("uri_preferences", comptime comptimeTableize("URIPreference"));
    try std.testing.expectEqualStrings("user_uri_preferences", comptime comptimeTableize("UserURIPreference"));
    try std.testing.expectEqualStrings("favorite_uris", comptime comptimeTableize("FavoriteURI"));
}
