const std = @import("std");

const httpz = @import("httpz");
const pg = @import("pg");

pub fn Cli(comptime AppArgument: type) type {
    return struct {
        allocator: std.mem.Allocator,
        app: *App,
        httpz_config: httpz.Config,

        const CliSelf = @This();
        pub const App = AppArgument;

        pub fn init(allocator: std.mem.Allocator, app: *App, httpz_config: httpz.Config) CliSelf {
            return .{
                .allocator = allocator,
                .app = app,
                .httpz_config = httpz_config,
            };
        }

        pub fn run(self: *CliSelf) !void {
            var args_arena_allocator = std.heap.ArenaAllocator.init(self.allocator);
            defer args_arena_allocator.deinit();

            const args_allocator = args_arena_allocator.allocator();

            var args = try std.process.argsWithAllocator(args_allocator);
            defer args.deinit();

            std.debug.assert(args.skip());
            const command_arg = args.next().?;

            inline for ([_]type{default_tasks} ++ App.tasks) |task_namespace| {
                inline for (@typeInfo(task_namespace).@"struct".decls) |decl| {
                    if (std.mem.eql(u8, command_arg, decl.name)) {
                        try @field(task_namespace, decl.name)(self, &args);
                        return;
                    }
                }
            }
            return error.UnknownCommand;
        }

        const default_tasks = struct {
            pub fn server(cli: *CliSelf, args: *std.process.ArgIterator) !void {
                _ = args;

                var httpz_server = try httpz.Server(*App.AppRouter).init(
                    cli.allocator,
                    cli.httpz_config,
                    &cli.app.router,
                );
                defer httpz_server.deinit();

                std.log.info("Listening at http://localhost:{d}", .{cli.httpz_config.port.?});
                try httpz_server.listen();
            }

            pub fn @"db:generate-migration"(cli: *CliSelf, args: *std.process.ArgIterator) !void {
                const migration_name = args.next() orelse return error.MissingMigrationName;
                const version = std.time.milliTimestamp();

                const cwd = std.fs.cwd();
                var migrations_dir = try cwd.makeOpenPath("src/db/migrations", .{});
                defer migrations_dir.close();

                const migration_file_path = try std.fmt.allocPrint(cli.allocator, "{s}.zig", .{migration_name});

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

            pub fn @"db:migrate"(cli: *CliSelf, args: *std.process.ArgIterator) !void {
                _ = args;

                var conn: *pg.Conn = try cli.app.pg_pool.acquire();
                defer conn.release();

                _ = try conn.exec(
                    \\CREATE TABLE IF NOT EXISTS schema_migrations (
                    \\    version bigint NOT NULL UNIQUE
                    \\);
                , .{});

                inline for (App.migrations) |migration| {
                    try conn.begin();

                    _ = conn.exec("SELECT pg_advisory_xact_lock($1)", .{db_migrate_advisory_lock_key}) catch |err| {
                        std.log.err("Migration failed ({s})", .{@errorName(err)});
                        try conn.rollback();
                        return error.UnableToAcquireMigrationLock;
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
                        migration.up(cli.app, conn) catch |err| {
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

                    std.log.info("Migrated {s} ({d})", .{ @typeName(migration), migration.version });
                    try conn.commit();
                }
            }

            pub fn @"db:rollback"(cli: *CliSelf, args: *std.process.ArgIterator) !void {
                _ = args;

                var conn: *pg.Conn = try cli.app.pg_pool.acquire();
                defer conn.release();

                _ = try conn.exec(
                    \\CREATE TABLE IF NOT EXISTS schema_migrations (
                    \\    version bigint NOT NULL UNIQUE
                    \\);
                , .{});

                try conn.begin();

                _ = conn.exec("SELECT pg_advisory_xact_lock($1)", .{db_migrate_advisory_lock_key}) catch |err| {
                    std.log.err("Rollback failed ({s})", .{@errorName(err)});
                    try conn.rollback();
                    return error.UnableToAcquireMigrationLock;
                };

                var latest_schema_migration_row = try conn.row("SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1", .{});
                if (latest_schema_migration_row == null) {
                    return error.NoMigrationToRollback;
                }
                const version = latest_schema_migration_row.?.get(i64, 0);
                try latest_schema_migration_row.?.deinit();

                inline for (App.migrations) |migration| {
                    if (migration.version == version) {
                        migration.down(cli.app, conn) catch |err| {
                            std.log.err("Rollback failed: ({s}): {s}", .{ @errorName(err), @typeName(migration) });
                            try conn.rollback();
                            return error.RollbackFailed;
                        };

                        _ = conn.exec("DELETE FROM schema_migrations WHERE version = $1", .{migration.version}) catch |err| {
                            std.log.err("Rollback failed ({s}): {s}", .{ @errorName(err), @typeName(migration) });
                            try conn.rollback();
                            return error.RollbackFailed;
                        };

                        std.log.info("Rolled back {s} ({d})", .{ @typeName(migration), migration.version });
                        try conn.commit();
                        return;
                    }
                }
                return error.MigrationNotFound;
            }
        };

        pub fn fatal(_: *const @This(), comptime format: []const u8, args: anytype) noreturn {
            const std_err = std.io.getStdOut();
            const std_err_writer = std_err.writer();

            if (std_err_writer.print(format, args)) {} else |_| {}
            if (std_err_writer.print("\n", .{})) {} else |_| {}
            std.process.exit(1);
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

const db_migrate_advisory_lock_key = db_migrate_advisory_lock_key: {
    var hasher: std.hash.XxHash32 = .init(7);
    hasher.update("db:migrate");
    break :db_migrate_advisory_lock_key hasher.final();
};
