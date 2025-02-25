const std = @import("std");
const zune = @import("zune");
const util = @import("mesh/import_files.zig");

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

    // const texture = try zune.graphics.Texture.createFromFile(allocator, "assets/textures/txtr.png");
    // const texture = try resource_manager.createTexture("assets/textures/txtr.png");
    // const texture = try resource_manager.createTexture("assets/models/Dune/colormap.png");
    const texture = try resource_manager.createTexture("assets/models/GrassCube/Grass_Block_TEX.png");
    // const texture = try resource_manager.createTexture("assets/models/Fish/fish_texture.png");
    // const texture = try resource_manager.createTexture("assets/models/Frog/frog.jpg");
    std.debug.print("finished loading texture...\n", .{});

    // const shader = try zune.graphics.Shader.createTextureShader(allocator);
    const shader = try resource_manager.createTextureShader();

    // const material = try zune.graphics.Material.create(allocator, shader, .{ 1.0, 1.0, 1.0, 1.0 }, texture);
    const material = try resource_manager.createMaterial("mapMaterial", shader, .{ 1.0, 1.0, 1.0, 1.0 }, texture);

    // const cube_mesh = try zune.graphics.Mesh.createCube(allocator);
    // const cube_mesh = try resource_manager.createCubeMesh();
    // const cube_mesh = try util.importObjRobust(resource_manager, "assets/models/Frog/frog.obj", "Frog");
    // const cube_mesh = try util.importObjRobust(resource_manager, "assets/models/Fish/fish.obj");
    const cube_mesh = try util.importObjRobust(resource_manager, "assets/models/Dune/lowresmodel.obj", "MapMesh", true);
    // const cube_mesh = try util.importObjRobust(resource_manager, "assets/models/Teapot/Teapot.obj");
    // const cube_mesh = try util.importObjRobust(resource_manager, "assets/models/GrassCube/Grass_Block.obj", "MapMesh");
    // const cube_mesh = try util.importObj(resource_manager, "assets/models/GrassCube/Grass_Block.obj");

    var cube_model = try resource_manager.createModel("MapModel");
    // var cube_model = try resource_manager.createModel("CubeModel");
    // var cube_model = try zune.graphics.Model.create(allocator);

    try cube_model.addMeshMaterial(cube_mesh, material);

    // --- Setup the ECS system --- //

    // Register components
    try gameSetup.ecs.registerComponent(zune.ecs.components.TransformComponent);
    try gameSetup.ecs.registerComponent(zune.ecs.components.ModelComponent);

    try gameSetup.ecs.registerComponent(Velocity);
    try gameSetup.ecs.registerComponent(Lifetime);

    // Create random generater
    var prng = std.Random.DefaultPrng.init(0);
    var random = prng.random();

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
            .x = (random.float(f32) - 0.5) * 0.2,
            .y = (random.float(f32) - 0.5) * 0.2,
        });

        // Random lifetime
        try gameSetup.ecs.addComponent(entity, Lifetime{
            .remaining = random.float(f32) * 10.0,
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

        // try updatePhysics(gameSetup.ecs);
        if (gameSetup.input.isKeyHeld(.KEY_SPACE)) gameSetup.camera.position = zune.math.Vec3{ .x = gameSetup.camera.position.x, .y = gameSetup.camera.position.y + 1, .z = gameSetup.camera.position.z };
        if (gameSetup.input.isKeyHeld(.KEY_W)) {
            const lookDir = zune.math.Vec3{ .x = -gameSetup.camera.view_matrix.data[2], .y = -gameSetup.camera.view_matrix.data[6], .z = -gameSetup.camera.view_matrix.data[10] };
            gameSetup.camera.position = gameSetup.camera.position.add(lookDir.scale(10));
            // gameSetup.camera.position = gameSetup.camera.
        }
        if (gameSetup.input.isKeyHeld(.KEY_LEFT_SHIFT)) gameSetup.camera.position = zune.math.Vec3{ .x = gameSetup.camera.position.x, .y = gameSetup.camera.position.y - 1, .z = gameSetup.camera.position.z };
        if (gameSetup.input.isKeyReleased(.KEY_ESCAPE)) break;

        gameSetup.renderer.clear();

        try render(gameSetup.ecs, gameSetup.camera);

        gameSetup.window.pollEvents();
        gameSetup.window.swapBuffers();
    }
}

const Velocity = struct {
    x: f32,
    y: f32,
    z: f32,
};

fn updatePhysics(registry: *zune.ecs.Registry) !void {
    var query = try registry.query(struct {
        transform: *zune.ecs.components.TransformComponent,
        velocity: *Velocity,
    });

    while (try query.next()) |components| {

        // Update position
        // components.transform.position[0] += components.velocity.x;
        // components.transform.position[1] += components.velocity.y;

        // Update lifetime
        // components.life.remaining -= 1.0 / 60.0;

        // rotate model
        components.transform.rotate(0.01, 0.02, 0.0);
    }
}

pub fn render(registry: *zune.ecs.Registry, camera: zune.graphics.Camera) !void {
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
