const std = @import("std");

const httpz = @import("httpz");

const cgi_escape = @import("cgi_escape.zig");
const CsrfToken = @import("CsrfToken.zig");
const url_form_encoded = @import("url_form_encoded.zig");
const validation = @import("validation.zig");
const view_helpers = @import("view_helpers.zig");

pub fn parse(T: type, form_data: anytype) !T {
    return try url_form_encoded.parse(T, form_data);
}

pub const FormOptions = struct {
    action: ?[]const u8,
    method: []const u8 = "POST",
};

pub fn Form(comptime Model: type) type {
    return struct {
        csrf_token: CsrfToken.FormScoped,
        model: Model,
        errors: validation.RecordErrors(Model),
        options: FormOptions,

        pub const BeginFormOptions = struct {
            class: ?[]const u8 = null,
        };

        const csrf_token_input_name = "_csrf_token";

        pub fn beginForm(self: *const @This(), writer: *std.Io.Writer, options: BeginFormOptions) !void {
            try view_helpers.beginForm(
                writer,
                .{ .action = self.options.action, .method = self.options.method, .class = options.class },
            );
            try view_helpers.writeInput(
                writer,
                csrf_token_input_name,
                &self.csrf_token,
                .{ .type = "hidden" },
            );
        }

        pub fn endForm(_: *const @This(), writer: *std.Io.Writer) !void {
            try view_helpers.endForm(writer);
        }

        pub fn writeField(self: *const @This(), writer: *std.Io.Writer, comptime name: std.meta.FieldEnum(Model), options: view_helpers.FieldOptions) !void {
            try view_helpers.writeRecordField(writer, self.model, &self.errors, name, options);
        }

        pub fn fields(self: *const @This(), comptime name: std.meta.FieldEnum(Model)) Fields(std.meta.fieldInfo(Model, name).type, @tagName(name)) {
            return .{ .model = &@field(self.model, @tagName(name)) };
        }
    };
}

pub fn Fields(comptime Model: type, comptime path_prefix: []const u8) type {
    return struct {
        model: *const Model,

        pub fn writeField(self: *const @This(), writer: *std.Io.Writer, comptime name: std.meta.FieldEnum(Model), options: view_helpers.FieldOptions) !void {
            const field_name = @tagName(name);
            try view_helpers.writeField(
                writer,
                @field(self.model, field_name),
                &[_]validation.Error{},
                path_prefix ++ "[" ++ field_name ++ "]",
                options,
            );
        }

        pub fn fields(self: *const @This(), comptime name: std.meta.FieldEnum(Model)) Fields(std.meta.fieldInfo(Model, name).type, path_prefix ++ "[" ++ @tagName(name) ++ "]") {
            return .{ .model = &@field(self.model, @tagName(name)) };
        }
    };
}

fn FormBuildOptions(Model: type) type {
    return struct {
        action: ?[]const u8 = null,
        method: []const u8 = "POST",
        errors: ?validation.RecordErrors(Model) = null,
    };
}

pub fn build(context: anytype, model: anytype, options: FormBuildOptions(@TypeOf(model))) Form(@TypeOf(model)) {
    const action = options.action orelse context.request.url.path;
    const method = options.method;

    return .{
        .csrf_token = context.session.csrf_token.formScoped(action, method),
        .model = model,
        .errors = options.errors orelse validation.RecordErrors(@TypeOf(model)).init(context.response.arena),
        .options = .{
            .action = options.action,
            .method = options.method,
        },
    };
}

pub fn formDataProtectedFromForgery(context: anytype, T: type) !?T {
    const action = context.request.url.path;
    const method = @tagName(context.request.method);
    const form_data = try context.request.formData();
    if (form_data.get("_csrf_token")) |form_data_csrf_token| {
        if (context.session.csrf_token.isValidFormScoped(action, method, form_data_csrf_token)) {
            return try parse(T, form_data);
        }
    }

    context.response.status = 403;
    context.response.body = "Something went wrong";
    return null;
}
