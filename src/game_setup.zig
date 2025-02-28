const std = @import("std");
const zune = @import("zune");

const MN = @import("globals.zig");

// Types
const Allocator = std.mem.Allocator;

pub const GameSetup = struct {
    allocator: Allocator,
    window: *zune.core.Window,
    renderer: *zune.graphics.Renderer,
    input: *zune.core.Input,
    camera: zune.graphics.Camera,
    ecs: *zune.ecs.Registry,
    // memoryLeakprt: *GameSetup,

    pub fn init(allocator: Allocator) !GameSetup {

        // ----- Initialize window -----
        var window = try zune.core.Window.create(allocator, .{
            .title = MN.WINDOW_TITLE,
            .width = MN.WINDOW_WIDTH,
            .height = MN.WINDOW_HEIGHT,
            // .decorated = false,
            // .transparent = true,
        });
        errdefer window.release();
        window.centerWindow();
        window.setCursorMode(.disabled);

        // ----- Initialize ECS -----
        var ecs = try zune.ecs.Registry.create(allocator);
        errdefer ecs.release();

        // ----- Initialize input -----
        const input = window.input.?;

        // ----- Initialize renderer -----
        var renderer = try zune.graphics.Renderer.create(allocator);
        errdefer renderer.release();

        // ----- Initialize camera -----
        var camera = zune.graphics.Camera.initPerspective(renderer, MN.CAMERA_FOV, MN.CAMERA_ASPECT, MN.CAMERA_NEAR, MN.CAMERA_FAR);
        camera.setPosition(.{ .x = 0, .y = 400.0, .z = 0 });
        camera.lookAt(.{ .x = 4000, .z = 4000 });

        return GameSetup{
            .allocator = allocator,
            .window = window,
            .renderer = renderer,
            .camera = camera,
            .ecs = ecs,
            .input = input,
        };
    }

    pub fn deinit(self: *GameSetup) void {
        self.ecs.release();
        self.window.release();
        self.renderer.release();
    }
};
