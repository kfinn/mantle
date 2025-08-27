const std = @import("std");
const assert = std.debug.assert;

const httpz = @import("httpz");

const cgi_escape = @import("cgi_escape.zig");
const ControllerContext = @import("ControllerContext.zig").ControllerContext;
const inflector = @import("inflector.zig");

const RouterError = error{unknown};

pub const ComptimeOptions = struct {
    root: ?Root = null,
    routes: []const Route,
    assets: []const type = &[_]type{},
};

fn RouteParams(comptime param_names: []const [:0]const u8) type {
    comptime {
        var fields: [param_names.len]std.builtin.Type.StructField = undefined;
        for (param_names, 0..) |field_name, index| {
            fields[index] = .{
                .name = field_name ++ "",
                .type = []const u8,
                .default_value_ptr = null,
                .is_comptime = false,
                .alignment = 0,
            };
        }
        const decls = [_]std.builtin.Type.Declaration{};

        return @Type(
            std.builtin.Type{
                .@"struct" = .{
                    .layout = .auto,
                    .fields = &fields,
                    .decls = &decls,
                    .is_tuple = false,
                },
            },
        );
    }
}

fn comptimeExtendParamNames(comptime param_names: []const [:0]const u8, comptime new_param_name: [:0]const u8) []const [:0]const u8 {
    comptime {
        var param_names_builder: [param_names.len + 1][:0]const u8 = undefined;
        var index = 0;
        while (index < param_names.len) : (index += 1) {
            param_names_builder[index] = param_names[index];
        }
        param_names_builder[param_names.len] = new_param_name;
        const final_param_names = param_names_builder;
        return &final_param_names;
    }
}

fn ExtendedRouteParams(comptime OldRouteParmas: type, comptime new_param_name: [:0]const u8) type {
    const param_names = comptimeExtendParamNames(std.meta.fieldNames(OldRouteParmas), new_param_name);
    return RouteParams(param_names);
}

fn extendRouteParams(comptime OldRouteParams: type, comptime new_param_name: [:0]const u8, old_route_params: OldRouteParams, new_param_value: []const u8) ExtendedRouteParams(OldRouteParams, new_param_name) {
    var extended_route_params: ExtendedRouteParams(OldRouteParams, new_param_name) = undefined;
    inline for (std.meta.fieldNames(OldRouteParams)) |field_name| {
        @field(extended_route_params, field_name) = @field(old_route_params, field_name);
    }
    @field(extended_route_params, new_param_name) = new_param_value;
    return extended_route_params;
}

pub fn Router(comptime App: type, comptime comptime_options: ComptimeOptions) type {
    return struct {
        fn renderServerError(response: *httpz.Response) void {
            response.status = 500;
            response.body = "Internal Error";
        }

        const empty_param_names: [0][:0]const u8 = .{};
        pub fn handle(self: *@This(), request: *httpz.Request, response: *httpz.Response) void {
            std.log.info("Handling {s} request for {s}", .{ @tagName(request.method), request.url.path });

            if (request.url.path[0] != '/') {
                renderServerError(response);
                return;
            }

            if (comptime_options.root) |root| {
                if (std.mem.eql(u8, request.url.path, "/")) {
                    self.performControllerAction(root.Controller, root.action, request, response, .{}) catch |err| {
                        std.log.err("error: {}", .{err});
                        if (@errorReturnTrace()) |error_return_trace| {
                            std.debug.dumpStackTrace(error_return_trace.*);
                        }
                        renderServerError(response);
                        return;
                    };
                }
            }

            if (self.handleRouteEntries(&empty_param_names, request, response, comptime_options.routes, request.url.path[1..], .{})) |handled| {
                if (handled) return;
            } else |err| {
                std.log.err("error: {}", .{err});
                if (@errorReturnTrace()) |error_return_trace| {
                    std.debug.dumpStackTrace(error_return_trace.*);
                }
                renderServerError(response);
                return;
            }

            if (self.handleAssets(request, response)) |handled| {
                if (handled) return;
            } else |err| {
                std.log.err("error: {}", .{err});
                if (@errorReturnTrace()) |error_return_trace| {
                    std.debug.dumpStackTrace(error_return_trace.*);
                }
                renderServerError(response);
                return;
            }

            response.status = 404;
            response.body = "Not Found";
        }

        fn handleRouteEntries(self: *@This(), comptime route_param_names: []const [:0]const u8, request: *httpz.Request, response: *httpz.Response, comptime routes: []const Route, path: []const u8, route_params: RouteParams(route_param_names)) !bool {
            inline for (routes) |route| {
                const handled = switch (route) {
                    .resource => |resource| try self.handleResource(route_param_names, request, response, resource, path, route_params),
                    .resources => |resources| try self.handleResources(route_param_names, request, response, resources, path, route_params),
                    .namespace => |namespace| try self.handleNamespace(route_param_names, request, response, namespace, path, route_params),
                };
                if (handled) {
                    return true;
                }
            }
            return false;
        }

        fn handleResource(self: *@This(), comptime route_param_names: []const [:0]const u8, request: *httpz.Request, response: *httpz.Response, comptime resource: Resource, path: []const u8, route_params: RouteParams(route_param_names)) !bool {
            const first_path_segment, const path_segments_after_name = splitFirstPathSegment(path);

            if (!std.mem.eql(u8, resource.name, first_path_segment)) {
                return false;
            }

            if (path_segments_after_name.len == 0) {
                if (request.method == .GET and std.meta.hasFn(resource.Controller, "show")) {
                    try self.performControllerAction(resource.Controller, "show", request, response, route_params);
                    return true;
                }
                return false;
            }
            const escaped_id_path_segment, const rest_path_segments = splitFirstPathSegment(path_segments_after_name);
            if (rest_path_segments.len == 0) {
                const id_path_segment = try cgi_escape.unescapeUriComponentAlloc(request.arena, escaped_id_path_segment);
                switch (request.method) {
                    .GET => {
                        if (std.mem.eql(u8, id_path_segment, "new") and std.meta.hasFn(resource.Controller, "new")) {
                            try self.performControllerAction(resource.Controller, "new", request, response, route_params);
                            return true;
                        }
                        if (std.mem.eql(u8, id_path_segment, "edit") and std.meta.hasFn(resource.Controller, "edit")) {
                            try self.performControllerAction(resource.Controller, "edit", request, response, route_params);
                            return true;
                        }
                        return false;
                    },
                    .POST => {
                        if (std.mem.eql(u8, id_path_segment, "new") and std.meta.hasFn(resource.Controller, "create")) {
                            try self.performControllerAction(resource.Controller, "create", request, response, route_params);
                            return true;
                        }
                        if (std.mem.eql(u8, id_path_segment, "edit") and std.meta.hasFn(resource.Controller, "update")) {
                            try self.performControllerAction(resource.Controller, "update", request, response, route_params);
                            return true;
                        }
                        return false;
                    },
                    else => {},
                }
                return false;
            }

            if (resource.routes) |child_routes| {
                return try self.handleRouteEntries(request, response, child_routes, rest_path_segments, route_params);
            }
            return false;
        }

        fn handleResources(self: *@This(), comptime route_param_names: []const [:0]const u8, request: *httpz.Request, response: *httpz.Response, comptime resources: Resources, path: []const u8, route_params: RouteParams(route_param_names)) !bool {
            const first_path_segment, const path_segments_after_name = splitFirstPathSegment(path);

            if (!std.mem.eql(u8, resources.name, first_path_segment)) {
                return false;
            }

            var context = try App.ControllerContext.init(
                self.app(),
                request,
                response,
            );
            defer context.deinit();

            if (path_segments_after_name.len == 0) {
                if (request.method == .GET) {
                    if (std.meta.hasFn(resources.Controller, "index")) {
                        try self.performControllerAction(resources.Controller, "index", request, response, route_params);
                        return true;
                    }
                }
                return false;
            }

            const escaped_id_path_segment, const rest_path_segments = splitFirstPathSegment(path_segments_after_name);
            const id_path_segment = try cgi_escape.unescapeUriComponentAlloc(request.arena, escaped_id_path_segment);

            if (rest_path_segments.len == 0) {
                switch (request.method) {
                    .GET => {
                        if (std.mem.eql(u8, id_path_segment, "new") and std.meta.hasFn(resources.Controller, "new")) {
                            try self.performControllerAction(resources.Controller, "new", request, response, route_params);
                            return true;
                        }
                        if (std.mem.eql(u8, id_path_segment, "edit") and std.meta.hasFn(resources.Controller, "edit")) {
                            try self.performControllerAction(resources.Controller, "edit", request, response, route_params);
                            return true;
                        }
                        if (std.meta.hasFn(resources.Controller, "show")) {
                            const route_params_with_id = extendRouteParams(@TypeOf(route_params), "id", route_params, id_path_segment);
                            try self.performControllerAction(resources.Controller, "show", request, response, route_params_with_id);
                            return true;
                        }
                    },
                    .POST => {
                        if (std.mem.eql(u8, id_path_segment, "new") and std.meta.hasFn(resources.Controller, "create")) {
                            try self.performControllerAction(resources.Controller, "create", request, response, route_params);
                            return true;
                        }
                        if (std.mem.eql(u8, id_path_segment, "edit") and std.meta.hasFn(resources.Controller, "update")) {
                            try self.performControllerAction(resources.Controller, "update", request, response, route_params);
                            return true;
                        }
                    },
                    else => {},
                }
                return false;
            }
            if (resources.routes) |child_routes| {
                const param_name = comptime std.fmt.comptimePrint("{s}_id", .{inflector.comptimeSingularize(resources.name)});
                const nested_route_param_names = comptime comptimeExtendParamNames(route_param_names, param_name);
                const route_params_with_id = extendRouteParams(@TypeOf(route_params), param_name, route_params, id_path_segment);
                return try self.handleRouteEntries(nested_route_param_names, request, response, child_routes, rest_path_segments, route_params_with_id);
            }
            return false;
        }

        fn handleNamespace(self: *@This(), comptime route_param_names: []const [:0]const u8, request: *httpz.Request, response: *httpz.Response, comptime namespace: Namespace, path: []const u8, route_params: RouteParams(route_param_names)) !bool {
            const first_path_segment, const rest_path_segments = splitFirstPathSegment(path);

            if (!std.mem.eql(u8, namespace.name, first_path_segment)) {
                return false;
            }

            if (namespace.routes) |child_routes| {
                return try self.handleRouteEntries(request, response, child_routes, rest_path_segments, route_params);
            }
            return false;
        }

        fn app(self: *@This()) *App {
            return @alignCast(@fieldParentPtr("router", self));
        }

        fn performControllerAction(self: *@This(), comptime Controller: type, comptime action_name: []const u8, request: *httpz.Request, response: *httpz.Response, params: anytype) !void {
            var context = try App.ControllerContext.init(
                self.app(),
                request,
                response,
            );
            defer context.deinit();

            std.log.info("Routing to {s}#{s}", .{ @typeName(Controller), action_name });

            const action_fn_type_info = @typeInfo(@TypeOf(@field(Controller, action_name))).@"fn";
            if (action_fn_type_info.params.len == 1) {
                try @field(Controller, action_name)(&context);
            } else {
                const ControllerParams = action_fn_type_info.params[1].type.?;
                var controller_params: ControllerParams = undefined;

                inline for (comptime std.meta.fieldNames(ControllerParams)) |field_name| {
                    @field(controller_params, field_name) = @field(params, field_name);
                }
                try @field(Controller, action_name)(&context, controller_params);
            }
            try context.afterAction();

            std.log.info("{s}#{s} responded with status {d}", .{ @typeName(Controller), action_name, response.status });
        }

        fn handleAssets(_: *const @This(), request: *httpz.Request, response: *httpz.Response) !bool {
            inline for (comptime_options.assets) |assets_library| {
                if (assets_library.All.has(request.url.path)) {
                    const self_exe_dir_path = try std.fs.selfExeDirPathAlloc(response.arena);
                    const asset_path = try std.fmt.allocPrint(response.arena, "{s}/../{s}", .{ self_exe_dir_path, request.url.path });

                    response.content_type = httpz.ContentType.forFile(asset_path);
                    response.header("Cache-Control", "max-age=31536000, immutable");

                    const file = try std.fs.openFileAbsolute(asset_path, .{});
                    defer file.close();

                    var buf: [1024 * 1024]u8 = undefined;
                    while (true) {
                        const bytes_read = try file.read(&buf);
                        if (bytes_read == 0) break;
                        try response.chunk(buf[0..bytes_read]);
                    }
                    return true;
                }
            }
            return false;
        }
    };
}

pub const Root = struct {
    Controller: type,
    action: []const u8,
};

pub const Route = union(enum) {
    namespace: Namespace,
    resource: Resource,
    resources: Resources,
};

pub const Namespace = struct {
    name: []const u8,
    routes: ?[]const Route,
};

pub const Resources = struct {
    name: []const u8,
    Controller: type,
    routes: ?[]const Route = null,
};

pub const Resource = struct {
    name: []const u8,
    Controller: type,
    routes: ?[]const Route = null,
};

fn splitFirstPathSegment(path: []const u8) [2][]const u8 {
    var iterator = std.mem.splitScalar(u8, path, '/');
    return .{ iterator.first(), iterator.rest() };
}
