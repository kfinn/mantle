const std = @import("std");
const Asset = @import("Asset.zig");

allocator: std.mem.Allocator,
dir: std.fs.Dir,
walker: std.fs.Dir.Walker,
opt_last_asset: ?Asset = null,

pub fn init(allocator: std.mem.Allocator, path: []const u8) !@This() {
    var dir = try std.fs.cwd().openDir(path, .{ .iterate = true, .no_follow = true });
    return .{
        .allocator = allocator,
        .dir = dir,
        .walker = try dir.walk(allocator),
    };
}

pub fn deinit(self: *@This()) void {
    if (self.opt_last_asset) |*last_asset| {
        last_asset.deinit();
    }
    self.walker.deinit();
    self.dir.close();
    self.* = undefined;
}

pub fn next(self: *@This()) !?Asset {
    if (self.opt_last_asset) |*last_asset| {
        last_asset.deinit();
        self.opt_last_asset = null;
    }

    while (try self.walker.next()) |walker_entry| {
        if (walker_entry.kind == .file and std.mem.containsAtLeastScalar(u8, walker_entry.basename, 1, '.')) {
            self.opt_last_asset = Asset.init(self.dir, walker_entry.path);
            return self.opt_last_asset;
        }
    }
    return null;
}
