const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("strfz", .{
        .root_source_file = b.path("src/strfz.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&run_tests.step);

    // zig build example
    {
        const exe = b.addExecutable(.{
            .name = "demo",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/demo.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            }),
        });
        exe.root_module.addImport("strfz", mod);
        const run = b.addRunArtifact(exe);
        b.step("example", "Run examples/demo.zig").dependOn(&run.step);
    }
}
