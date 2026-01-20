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

pub fn beginForm(writer: *std.Io.Writer, opts: BeginFormOptions) !void {
    try writeHtmlTag(writer, "form", opts, .{});
}

pub fn endForm(writer: *std.Io.Writer) !void {
    try writer.writeAll("</form>");
}

pub const ErrorsOptions = struct {
    class: ?[]const u8 = null,
};

pub fn writeFieldErrors(writer: *std.Io.Writer, errors: anytype, field: @TypeOf(errors).Field, options: ErrorsOptions) !void {
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
    input: FieldInputOptions = .{ .text = .{} },
    errors: ErrorsOptions = .{},
};

fn htmlAttributeField(name: [:0]const u8) std.builtin.Type.StructField {
    const null_default_value = comptime null;
    return .{
        .name = name,
        .type = ?[]const u8,
        .default_value_ptr = &null_default_value,
        .is_comptime = false,
        .alignment = @alignOf([]const u8),
    };
}

pub const HiddenInputOptions = struct {
    comptime type: []const u8 = "hidden",
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    autofocus: ?bool = null,
    class: ?[]const u8 = null,
    autocomplete: ?[]const u8 = null,
};

pub const TextInputOptions = struct {
    comptime type: []const u8 = "text",
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    autofocus: ?bool = false,
    class: ?[]const u8 = null,
    autocomplete: ?[]const u8 = null,
};

pub const EmailInputOptions = struct {
    comptime type: []const u8 = "email",
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    autofocus: ?bool = false,
    class: ?[]const u8 = null,
    autocomplete: ?[]const u8 = null,
};

pub const PasswordInputOptions = struct {
    comptime type: []const u8 = "password",
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    autofocus: ?bool = false,
    class: ?[]const u8 = null,
    autocomplete: ?[]const u8 = null,
};

pub const NumberInputOptions = struct {
    comptime type: []const u8 = "number",
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    autofocus: ?bool = false,
    class: ?[]const u8 = null,
    autocomplete: ?[]const u8 = null,
    min: ?[]const u8 = null,
    max: ?[]const u8 = null,
};

pub const TimeInputOptions = struct {
    comptime type: []const u8 = "time",
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    autofocus: ?bool = false,
    class: ?[]const u8 = null,
    autocomplete: ?[]const u8 = null,
};

pub const FieldInputOptions = union(enum) {
    text: TextInputOptions,
    email: EmailInputOptions,
    password: PasswordInputOptions,
    number: NumberInputOptions,
    time: TimeInputOptions,
    select: SelectOptions,
    checkbox: CheckboxOptions,
};

pub const LabelOptions = struct {
    name: ?[]const u8 = null,
    class: ?[]const u8 = null,
};

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

fn applyInputDefaults(options: anytype, name: []const u8, value: []const u8) void {
    if (options.id == null) options.id = name;
    if (options.name == null) options.name = name;
    if (options.value == null) options.value = value;
}

pub fn writeField(
    writer: *std.Io.Writer,
    value: []const u8,
    errors: []validation.Error,
    comptime name: []const u8,
    options: FieldOptions,
) !void {
    if (options.input == .checkbox) {
        const checkbox_options = options.input.checkbox;
        try writeHtmlTag(writer, "label", .{ .@"for" = name, .class = options.label.class }, .{});
        try writeCheckbox(writer, name, value, checkbox_options);
        try writer.writeAll("<span>");
        try cgi_escape.writeEscapedHtml(writer, options.label.name orelse comptime inflector.comptimeHumanize(name));
        try writer.writeAll("</span>");
        try writer.writeAll("<div>");
        try writeErrors(writer, errors, options.errors);
        try writer.writeAll("</div>");
        try writer.writeAll("</label>");
        return;
    }

    try writeHtmlTag(writer, "label", .{ .@"for" = name, .class = options.label.class }, .{});
    try writer.writeAll("<span>");
    try cgi_escape.writeEscapedHtml(writer, options.label.name orelse comptime inflector.comptimeHumanize(name));
    try writer.writeAll("</span>");
    switch (options.input) {
        .select => |select_options| {
            try writeSelect(writer, name, value, select_options);
        },
        .checkbox => {
            unreachable;
        },
        .text => |text_options| {
            try writeInput(writer, name, value, text_options);
        },
        .email => |email_options| {
            try writeInput(writer, name, value, email_options);
        },
        .password => |password_options| {
            try writeInput(writer, name, value, password_options);
        },
        .number => |number_options| {
            try writeInput(writer, name, value, number_options);
        },
        .time => |time_options| {
            try writeInput(writer, name, value, time_options);
        },
    }
    try writer.writeAll("<div>");
    try writeErrors(writer, errors, options.errors);
    try writer.writeAll("</div>");
    try writer.writeAll("</label>");
}

pub fn writeInput(writer: *std.Io.Writer, name: []const u8, value: []const u8, options: anytype) !void {
    var options_with_defaults = options;
    if (options_with_defaults.id == null) options_with_defaults.id = name;
    if (options_with_defaults.name == null) options_with_defaults.name = name;
    if (options_with_defaults.value == null) options_with_defaults.value = value;
    try writeHtmlTag(writer, "input", options_with_defaults, .{ .self_closing = true });
}

pub const SelectOptions = struct {
    options: []const Option,
    class: ?[]const u8 = null,

    pub const Option = struct {
        label: []const u8,
        value: []const u8,
    };
};

pub fn writeSelect(writer: *std.Io.Writer, name: []const u8, value: []const u8, options: SelectOptions) !void {
    try writeHtmlTag(
        writer,
        "select",
        .{
            .class = options.class,
            .name = name,
            .id = name,
        },
        .{},
    );
    for (options.options) |option| {
        try writeHtmlTag(
            writer,
            "option",
            .{
                .selected = std.mem.eql(u8, value, option.value),
                .value = option.value,
            },
            .{},
        );
        try cgi_escape.writeEscapedHtml(writer, option.label);
        try writer.writeAll("</option>");
    }
    try writer.writeAll("</select>");
}

pub const CheckboxOptions = struct {
    class: ?[]const u8 = null,
};

pub fn writeCheckbox(writer: *std.Io.Writer, name: []const u8, value: []const u8, options: CheckboxOptions) !void {
    try writeHtmlTag(
        writer,
        "input",
        .{
            .type = "checkbox",
            .name = name,
            .id = name,
            .value = "1",
            .checked = std.mem.eql(u8, "1", value),
            .class = options.class,
        },
        .{ .self_closing = true },
    );
    try writeHtmlTag(
        writer,
        "input",
        .{
            .type = "hidden",
            .name = name,
            .value = "0",
            .class = options.class,
        },
        .{ .self_closing = true },
    );
}

pub const SubmitOptions = struct {
    class: ?[]const u8 = null,
};

pub fn writeSubmit(writer: *std.Io.Writer, value: []const u8, options: SubmitOptions) !void {
    try writeHtmlTag(writer, "input", .{ .type = "submit", .value = value, .class = options.class }, .{ .self_closing = true });
}
