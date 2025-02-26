const std = @import("std");
const zune = @import("zune");
const util = @import("mesh/import_files.zig");
const mesh = @import("mesh/processing.zig");

const MN = @import("globals.zig");

const GameSetup = @import("game_setup.zig").GameSetup;

pub fn main() !void {
    std.debug.print("Started program...\n", .{});
    // === Initialize Everything === //
    // --- Initialize allocator --- //
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // --- Initialize resource manager --- //
    var resource_manager = try zune.graphics.ResourceManager.create(allocator);
    defer _ = resource_manager.releaseAll();

    // --- Initialize game --- //
    var gameSetup = try GameSetup.init(allocator);
    defer gameSetup.deinit();

    // === Set Variables === //
    const initial_mouse_pos = gameSetup.input.getMousePosition();
    var camera_controller = zune.graphics.CameraMouseController.init(&gameSetup.camera, @as(f32, @floatCast(initial_mouse_pos.x)), @as(f32, @floatCast(initial_mouse_pos.y)));

    // === Create resources === //

    const texture = try resource_manager.createTexture("assets/textures/txtr.png");
    const shader = try resource_manager.createTextureShader();
    const material = try resource_manager.createMaterial("player_material", shader, .{ 1.0, 1.0, 1.0, 1.0 }, texture);
    // const cube_mesh = try util.importZMeshObj(resource_manager, "assets/models/Dune/lowresmodel.obj", "MapMesh");

    var phMapMesh = try util.importPHMeshObj(resource_manager, "assets/models/Dune/lowresmodel.obj");
    // mesh.zeroMesh(phMapMesh);
    // std.debug.print("BBMap: {any}\n", .{phMapMesh.getBoundingBox()});
    // const phMapSlices = try mesh.splitMesh(allocator, phMapMesh, .{ .x = 2000 }, .{ .z = 1 });
    // defer phMapSlices[1].deinit();
    // const cube_mesh = try phMapSlices[0].toMesh(resource_manager, "MapMesh");

    // var cube_model = try resource_manager.createModel("cube_model");
    const cube_model = try mesh.chunkMesh2Model(resource_manager, &phMapMesh, material, 10, 10, "MapModel");

    // try cube_model.addMeshMaterial(cube_mesh, material);

    // --- Setup the ECS system --- //

    // Register components
    try gameSetup.ecs.registerComponent(zune.ecs.components.TransformComponent);
    try gameSetup.ecs.registerComponent(zune.ecs.components.ModelComponent);

    try gameSetup.ecs.registerComponent(Velocity);

    // Create random generater

    // Spawn 1 particle entities
    var i: usize = 0;
    while (i < 1) : (i += 1) {
        const entity = try gameSetup.ecs.createEntity();

        var transform = zune.ecs.components.TransformComponent.identity();
        transform.setPosition(
            0.0, //random.float(f32),
            0.0, // random.float(f32),
            0.0,
        );

        // Random position
        try gameSetup.ecs.addComponent(entity, transform);

        // Random velocity
        try gameSetup.ecs.addComponent(entity, Velocity{
            .x = 0.1,
            .y = 0.1,
            .z = 0.1,
        });

        // Set Model to render
        try gameSetup.ecs.addComponent(entity, zune.ecs.components.ModelComponent.init(cube_model));
    }

    // --- Main Loop --- //

    while (!gameSetup.window.shouldClose()) {
        try gameSetup.input.update();

        // ==== Process Input ==== \\
        const mouse_pos = gameSetup.input.getMousePosition();
        camera_controller.handleMouseMovement(@as(f32, @floatCast(mouse_pos.x)), @as(f32, @floatCast(mouse_pos.y)), 1.0 / 60.0);

        try playerControlsSystem(gameSetup.ecs, gameSetup.input);

        if (gameSetup.input.isKeyReleased(.KEY_ESCAPE)) break;

        gameSetup.renderer.clear();

        try renderSystem(gameSetup.ecs, gameSetup.camera);

        gameSetup.window.pollEvents();
        gameSetup.window.swapBuffers();
    }
}

const Velocity = struct {
    x: f32,
    y: f32,
    z: f32,
};

fn playerControlsSystem(registry: *zune.ecs.Registry, input: *zune.core.Input) !void {
    var query = try registry.query(struct {
        transform: *zune.ecs.components.TransformComponent,
        velocity: *Velocity,
    });

    while (try query.next()) |components| {
        // Update position
        if (input.isKeyHeld(.KEY_W) or input.isKeyPressed(.KEY_W)) {
            //std.debug.print("W\n", .{});
            components.velocity.z = -10;
            components.transform.position[2] += components.velocity.z;
        }

        if (input.isKeyHeld(.KEY_S) or input.isKeyPressed(.KEY_S)) {
            //std.debug.print("S\n", .{});
            components.velocity.z = 10;
            components.transform.position[2] += components.velocity.z;
        }

        if (input.isKeyHeld(.KEY_D) or input.isKeyPressed(.KEY_D)) {
            //std.debug.print("D\n", .{});
            components.velocity.x = 10;
            components.transform.position[0] += components.velocity.x;
        }

        if (input.isKeyHeld(.KEY_A) or input.isKeyPressed(.KEY_A)) {
            //std.debug.print("A\n", .{});
            components.velocity.x = -10;
            components.transform.position[0] += components.velocity.x;
        }
    }
}

pub fn renderSystem(registry: *zune.ecs.Registry, camera: zune.graphics.Camera) !void {
    // Query for entities with all required components
    var query = try registry.query(struct {
        transform: *zune.ecs.components.TransformComponent,
        model: *zune.ecs.components.ModelComponent,
    });

    while (try query.next()) |components| {
        // Skip if not visible
        if (!components.model.visible) continue;

        // Update transform matrices
        components.transform.updateMatrices();

        // Draw the model using current transform
        try camera.drawModel(
            components.model.model,
            &components.transform.world_matrix,
        );
    }
}
