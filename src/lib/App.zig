const httpz = @import("httpz");
const std = @import("std");
const pg = @import("pg");

const router_module = @import("Router.zig");
const Router = router_module.Router;

const controller_context = @import("ControllerContext.zig");

pub const ComptimeOptions = struct {
    router: router_module.ComptimeOptions,
    Session: type = struct {},
    migrations: []const type = &[_]type{},
    tasks: []const type = &[_]type{},
};

pub const Config = struct {
    db: pg.Pool.Opts,
    session: struct {
        cookie_secret_key: *const [32]u8,
    },
};

fn migrationLessThanFn(_: void, lhs: type, rhs: type) bool {
    return lhs.version < rhs.version;
}

pub fn App(comptime comptime_options: ComptimeOptions) type {
    const sorted_migrations = comptime sorted_migrations: {
        var buf: [comptime_options.migrations.len]type = undefined;
        for (comptime_options.migrations, 0..) |migration, index| {
            buf[index] = migration;
        }
        std.sort.pdq(type, &buf, void{}, migrationLessThanFn);
        break :sorted_migrations buf;
    };

    return struct {
        config: Config,
        router: AppRouter = .{},
        pg_pool: *pg.Pool,

        const AppSelf = @This();
        pub const AppRouter = Router(AppSelf, comptime_options.router);
        pub const ControllerContext = controller_context.ControllerContext(AppSelf);
        pub const Session = comptime_options.Session;
        pub const migrations = sorted_migrations;
        pub const tasks = comptime_options.tasks;

        pub fn init(allocator: std.mem.Allocator, config: Config) !@This() {
            return .{
                .config = config,
                .pg_pool = try pg.Pool.init(allocator, config.db),
            };
        }

        pub fn deinit(self: *@This()) void {
            self.pg_pool.deinit();
            self.* = undefined;
        }
    };
}
