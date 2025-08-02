const std = @import("std");

const httpz = @import("httpz");
const pg = @import("pg");

pub fn Cli(comptime AppArgument: type) type {
    return struct {
        allocator: std.mem.Allocator,
        app: *App,
        httpz_config: httpz.Config,

        pub const App = AppArgument;

        pub fn init(allocator: std.mem.Allocator, app: *App, httpz_config: httpz.Config) @This() {
            return .{
                .allocator = allocator,
                .app = app,
                .httpz_config = httpz_config,
            };
        }

        pub fn run(self: *@This()) !void {
            var args_arena_allocator = std.heap.ArenaAllocator.init(self.allocator);
            defer args_arena_allocator.deinit();

            const args_allocator = args_arena_allocator.allocator();

            var args = try std.process.argsWithAllocator(args_allocator);
            defer args.deinit();

            std.debug.assert(args.skip());
            const command_arg = args.next().?;

            if (std.mem.eql(u8, command_arg, "server")) {
                try self.server();
            } else if (std.mem.eql(u8, command_arg, "db:generate-migration")) {
                try self.dbGenerateMigration(&args);
            } else if (std.mem.eql(u8, command_arg, "db:migrate")) {
                try self.dbMigrate();
            } else {
                return error.UnknownCommand;
            }
        }

        fn server(self: *@This()) !void {
            var httpz_server = try httpz.Server(*App.AppRouter).init(
                self.allocator,
                self.httpz_config,
                &self.app.router,
            );
            defer httpz_server.deinit();

            std.log.info("Listening at http://localhost:{d}", .{self.httpz_config.port.?});
            try httpz_server.listen();
        }

        fn dbGenerateMigration(self: *@This(), args: *std.process.ArgIterator) !void {
            const migration_name = args.next() orelse return error.MissingMigrationName;
            const version = std.time.milliTimestamp();

            const cwd = std.fs.cwd();
            var migrations_dir = try cwd.makeOpenPath("src/db/migrations", .{});
            defer migrations_dir.close();

            const migration_file_path = try std.fmt.allocPrint(self.allocator, "{s}.zig", .{migration_name});

            if (migrations_dir.statFile(migration_file_path)) |_| {
                return error.MigrationAlreadyExists;
            } else |_| {}

            const migration_file = try migrations_dir.createFile(migration_file_path, .{});
            defer migration_file.close();

            const writer = migration_file.writer();

            try writer.print(
                \\const std = @import("std");
                \\const pg = @import("pg");
                \\
                \\pub const version: i64 = {d};
                \\
                \\pub fn up(app: anytype, conn: *pg.Conn) !void {{
                \\   _ = app;
                \\   _ = conn;
                \\}}
                \\
                \\pub fn down(app: anytype, conn: *pg.Conn) !void {{
                \\   _ = app;
                \\   _ = conn;
                \\}}
                \\
            , .{version});
        }

        fn dbMigrate(self: *@This()) !void {
            var conn: *pg.Conn = try self.app.pg_pool.acquire();
            defer conn.release();

            _ = try conn.exec(
                \\CREATE TABLE IF NOT EXISTS schema_migrations (
                \\    version bigint NOT NULL UNIQUE
                \\);
            , .{});

            inline for (App.migrations) |migration| {
                try conn.begin();
                var hasher: std.hash.XxHash32 = .init(7);
                hasher.update("migrate-");
                var migration_version_buf: [8]u8 = undefined;
                std.mem.writeInt(i64, &migration_version_buf, migration.version, .big);
                hasher.update(&migration_version_buf);
                const advisory_lock_key = hasher.final();

                _ = conn.exec("SELECT pg_advisory_xact_lock($1)", .{advisory_lock_key}) catch |err| {
                    std.log.err("Migration failed ({s}): {s}", .{ @errorName(err), @typeName(migration) });
                    try conn.rollback();
                    return error.MigrationFailed;
                };

                var schema_migration_exists_row = conn.row(
                    "SELECT EXISTS(SELECT * FROM schema_migrations WHERE version = $1) AS schema_migration_exists",
                    .{migration.version},
                ) catch |err| {
                    std.log.err("Migration failed ({s}): {s}", .{ @errorName(err), @typeName(migration) });
                    try conn.rollback();
                    return error.MigrationFailed;
                } orelse unreachable;
                const schema_migration_exists = schema_migration_exists_row.get(bool, 0);
                try schema_migration_exists_row.deinit();

                if (!schema_migration_exists) {
                    migration.up(self.app, conn) catch |err| {
                        std.log.err("Migration failed ({s}): {s}", .{ @errorName(err), @typeName(migration) });
                        if (@errorReturnTrace()) |error_return_trace| {
                            std.debug.dumpStackTrace(error_return_trace.*);
                        }
                        try conn.rollback();
                        return error.MigrationFailed;
                    };

                    _ = conn.exec("INSERT INTO schema_migrations (version) VALUES ($1)", .{migration.version}) catch |err| {
                        std.log.err("Migration failed ({s}): {s}", .{ @errorName(err), @typeName(migration) });
                        try conn.rollback();
                        return error.MigrationFailed;
                    };
                }

                try conn.commit();
            }
        }
    };
}

pub fn main(allocator: std.mem.Allocator, app: anytype, httpz_config: httpz.Config) !void {
    var cli = Cli(@TypeOf(app.*)).init(
        allocator,
        app,
        httpz_config,
    );
    try cli.run();

    std.process.cleanExit();
}
