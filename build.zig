const std = @import("std");

pub fn build(b: *std.Build) void {
    // Set target and optimization
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
    } });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .Debug });

    // Create the zune module that will be shared across all examples
    const libzune = b.addModule("zune", .{
        .root_source_file = b.path("zune/src/root.zig"),
        .optimize = optimize,
        .target = target,
    });
    libzune.addIncludePath(b.path("zune/dependencies/include/"));

    libzune.addObjectFile(b.path("zune/dependencies/lib/libglfw3.a"));
    libzune.addCSourceFile(.{ .file = b.path("zune/dependencies/lib/glad.c") });
    libzune.addCSourceFile(.{ .file = b.path("zune/dependencies/lib/stb_image.c") });
    libzune.addCSourceFile(.{ 
        .file = b.path("zune/dependencies/lib/eigen_wrapper.cpp"),
        .flags = &[_][]const u8{
            "-std=c++17",  // Use C++17 or higher
            "-fno-exceptions", // Optional: disable exceptions if not needed
        }, 
    });

    // create example executable
    const exe = b.addExecutable(.{
        .name = "Zune_rts",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // // Add clibraries from ucrt64
    // exe.addIncludePath(b.path("C:/msys64/ucrt64/include"));
    // exe.addLibraryPath(b.path(.cwd_relative("C:/msys64/ucrt64/lib")));

    exe.linkSystemLibrary("stdc++"); // Ensure C++ standard library is linked


    exe.root_module.addImport("zune", libzune);

    exe.linkLibC();

    // Windows-specific libraries
    exe.linkSystemLibrary("gdi32");
    exe.linkSystemLibrary("user32");
    exe.linkSystemLibrary("kernel32");
    exe.linkSystemLibrary("opengl32");

    // Add the C++ wrapper files
    exe.addCSourceFile(.{
        .file = b.path("dependencies/wrappers/eigen.cpp"),
        .flags = &[_][]const u8{
            "-std=c++17", // Use C++17 or higher
            "-fno-exceptions", // Optional: disable exceptions if not needed
        },
    });
    exe.addIncludePath(b.path("dependencies/wrappers")); // Your wrapper header

    exe.addIncludePath(b.path("zune/dependencies/include/")); // library


    // Create install step
    const install_step = b.addInstallArtifact(exe, .{});

    // Create run step
    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Create a specialized run step for this example
    const run_step = b.step("run", "Run the example");
    run_step.dependOn(&install_step.step);
    run_step.dependOn(&run_cmd.step);
}
