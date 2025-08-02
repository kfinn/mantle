const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.addModule("mantle", .{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const assets_exe_mod = b.createModule(.{
        .root_source_file = b.path("src/tools/assets/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const assets_exe = b.addExecutable(.{
        .name = "assets",
        .root_module = assets_exe_mod,
    });
    b.installArtifact(assets_exe);

    const lib_static_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const httpz_mod = b.dependency("httpz", .{
        .target = target,
        .optimize = optimize,
    }).module("httpz");
    lib_static_mod.addImport("httpz", httpz_mod);

    const pg_mod = b.dependency("pg", .{
        .target = target,
        .optimize = optimize,
    }).module("pg");
    lib_static_mod.addImport("pg", pg_mod);

    const lib_static = b.addLibrary(.{
        .name = "mantle",
        .linkage = .static,
        .root_module = lib_static_mod,
    });
    b.installArtifact(lib_static);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);
}

pub const AssetsImportOptions = struct {
    path: std.Build.LazyPath,
    import_name: []const u8 = "assets",
};

pub fn addAssetsImport(module: *std.Build.Module, options: AssetsImportOptions) *std.Build.Module {
    const b = module.owner;

    const mantle_dep = b.dependency("mantle", .{ .target = b.graph.host });
    const assets_exe = mantle_dep.artifact("assets");

    const assets_list_only_step = b.addRunArtifact(assets_exe);
    assets_list_only_step.has_side_effects = true;
    assets_list_only_step.addArg("list");
    const assets_list_only_output = assets_list_only_step.addOutputFileArg("assets_list.txt");
    assets_list_only_step.addDirectoryArg(options.path);

    const assets_generate_step = b.addRunArtifact(assets_exe);
    assets_generate_step.addArg("generate");
    const assets_zig_output = assets_generate_step.addOutputFileArg("assets.zig");
    const assets_dir_output = assets_generate_step.addOutputDirectoryArg("assets");
    assets_generate_step.addDirectoryArg(options.path);
    _ = assets_generate_step.addDepFileOutputArg("assets.d");
    assets_generate_step.addFileInput(assets_list_only_output);

    const assets_mod = b.createModule(.{ .root_source_file = assets_zig_output });
    module.addImport(options.import_name, assets_mod);

    const install_assets = b.addInstallDirectory(.{
        .source_dir = assets_dir_output,
        .install_dir = .{ .prefix = {} },
        .install_subdir = "assets",
    });
    b.getInstallStep().dependOn(&install_assets.step);

    return assets_mod;
}

pub fn addMantlePeerImports(mantle_mod: *std.Build.Module, peer_modules: struct { pg: *std.Build.Module, httpz: *std.Build.Module }) void {
    mantle_mod.addImport("pg", peer_modules.pg);
    mantle_mod.addImport("httpz", peer_modules.httpz);
}
