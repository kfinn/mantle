const std = @import("std");

const cgi_escape = @import("cgi_escape.zig");
const inflector = @import("inflector.zig");
const validation = @import("validation.zig");

pub const HtmlTagOptions = struct {
    self_closing: bool = false,
};

pub fn writeHtmlTag(writer: *std.Io.Writer, name: []const u8, attributes: anytype, options: HtmlTagOptions) !void {
    try writer.print("<{s}", .{name});
    try writeHtmlAttributes(writer, attributes);
    if (options.self_closing) try writer.writeByte('/');
    try writer.writeByte('>');
}

fn writeHtmlAttributes(writer: *std.Io.Writer, attributes: anytype) !void {
    inline for (@typeInfo(@TypeOf(attributes)).@"struct".fields) |field| {
        try writeHtmlAttribute(writer, field.name, @field(attributes, field.name));
    }
}

pub fn writeHtmlAttribute(writer: *std.Io.Writer, name: []const u8, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .optional => {
            if (value) |child| {
                try writeHtmlAttribute(writer, name, child);
            }
        },
        .bool => {
            if (value) {
                try writer.print(" {s}", .{name});
            }
        },
        else => {
            try writer.print(" {s}=\"", .{name});
            try cgi_escape.writeEscapedHtmlAttribute(writer, value);
            try writer.writeAll("\"");
        },
    }
}

pub const BeginFormOptions = struct {
    action: ?[]const u8 = null,
    method: ?[]const u8 = null,
    class: ?[]const u8 = null,
};

pub fn beginForm(writer: *std.Io.Writer, opts: BeginFormOptions) std.Io.Writer.Error!void {
    try writeHtmlTag(writer, "form", opts, .{});
}

pub fn endForm(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("</form>");
}

pub const ErrorsOptions = struct {
    class: ?[]const u8 = null,
};

pub fn writeFieldErrors(writer: *std.Io.Writer, errors: anytype, field: @TypeOf(errors).Field, options: ErrorsOptions) std.Io.Writer.Error!void {
    try writeErrors(writer, errors.field_errors.get(field).items, options);
}

pub fn writeErrors(writer: *std.Io.Writer, errors: []validation.Error, options: ErrorsOptions) !void {
    if (errors.len == 0) {
        return;
    }

    try writeHtmlTag(writer, "span", options, .{});

    var requires_leading_comma = false;
    for (errors) |validation_error| {
        if (requires_leading_comma) try writer.writeAll(", ");
        try cgi_escape.writeEscapedHtml(writer, validation_error.description);
        requires_leading_comma = true;
    }

    try writer.writeAll("</span>");
}
pub const FieldOptions = struct {
    label: LabelOptions = .{},
    input: InputOptions = .{},
};

pub const LabelOptions = struct { class: ?[]const u8 = null };

pub fn writeRecordField(
    writer: *std.Io.Writer,
    model: anytype,
    errors: *const validation.RecordErrors(@TypeOf(model)),
    comptime name: std.meta.FieldEnum(@TypeOf(model)),
    options: FieldOptions,
) !void {
    try writeField(
        writer,
        @field(model, @tagName(name)),
        errors.field_errors.get(name).items,
        @tagName(name),
        options,
    );
}

pub fn writeField(
    writer: *std.Io.Writer,
    value: []const u8,
    errors: []validation.Error,
    comptime name: []const u8,
    options: FieldOptions,
) !void {
    const title_case_field_name = comptime inflector.comptimeHumanize(name);

    try writeHtmlTag(writer, "label", .{ .@"for" = name, .class = options.label.class }, .{});
    try writer.writeAll("<span>");
    try cgi_escape.writeEscapedHtml(writer, title_case_field_name);
    try writer.writeAll("</span>");
    try writeInput(writer, name, value, .{
        .autofocus = options.input.autofocus,
        .type = options.input.type,
        .class = options.input.class,
    });
    try writer.writeAll("<div>");
    try writeErrors(writer, errors, .{});
    try writer.writeAll("</div>");
    try writer.writeAll("</label>");
}

pub const InputOptions = struct {
    autofocus: ?bool = null,
    type: ?[]const u8 = null,
    class: ?[]const u8 = null,
};

pub fn writeInput(writer: *std.Io.Writer, name: []const u8, value: []const u8, options: InputOptions) std.Io.Writer.Error!void {
    try writeHtmlTag(
        writer,
        "input",
        .{
            .name = name,
            .value = value,
            .autofocus = options.autofocus,
            .type = options.type,
            .class = options.class,
        },
        .{},
    );
}

pub const SubmitOptions = struct {
    class: ?[]const u8 = null,
};

pub fn writeSubmit(writer: *std.Io.Writer, value: []const u8, options: SubmitOptions) !void {
    try writeHtmlTag(writer, "input", .{ .type = "submit", .value = value, .class = options.class }, .{ .self_closing = true });
}
