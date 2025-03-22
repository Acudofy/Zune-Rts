const std = @import("std");
const zune = @import("zune");
const zmath = zune.math;
const util = @import("mesh/import_files.zig");
const mesh_processing = @import("mesh/processing.zig");
const mesh_simplification = @import("mesh/cuthulus_box.zig");
const math = @import("math.zig");

const MN = @import("globals.zig");

const Map = @import("world/map.zig").Map;
const GameSetup = @import("game_setup.zig").GameSetup;
const PlaceHolderMesh = mesh_processing.PlaceHolderMesh;

const Allocator = std.mem.Allocator;
const ECS = zune.ecs.Registry;
const Model = zune.ecs.components.ModelComponent;
const Transform = zune.ecs.components.TransformComponent;
const Mesh = zune.graphics.Mesh;

pub fn main() !void {
    std.debug.print("Started program...\n", .{});
    // ===== Initialize Everything ===== //
    // ----- Initialize allocator ----- //
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();

    // ----- Initialize resource manager ----- //
    var resource_manager = try zune.graphics.ResourceManager.create(allocator, .{ .enabled = false });
    defer _ = resource_manager.releaseAll() catch std.debug.print("all your errors are belong to us\n", .{});

    // ----- Initialize game ----- //
    var gameSetup = try GameSetup.init(allocator);
    defer gameSetup.deinit();

    // ===== Set Variables ===== //
    const initial_mouse_pos = gameSetup.input.getMousePosition();
    var camera_controller = zune.graphics.CameraMouseController.init(&gameSetup.camera, @as(f32, @floatCast(initial_mouse_pos.x)), @as(f32, @floatCast(initial_mouse_pos.y)));

    // ===== Register ECS-Components =====
    try ecsGeneralComponents(gameSetup.ecs);
    try ecsMap(gameSetup.ecs);

    // ===== Setup game =====
    try setActiveMap(gameSetup.ecs, 0, resource_manager, &gameSetup.camera);

    // =====================
    // ===== TEST CODE =====
    // =====================
    var testMesh = try util.importPHMeshObj(resource_manager, "assets/models/Teapot/Teapot.obj");
    defer testMesh.deinit();
    const meshBB = testMesh.getBoundingBox();
    const meshSize = meshBB.max.subtract(meshBB.min);
    var collapse_err:f32 = @max(meshSize.x, meshSize.y, meshSize.z)/1000;

    std.debug.print("triangleCount: {}\n", .{testMesh.triangleCount});
    std.debug.print("indices.len: {}\n", .{testMesh.indices.len});
    std.debug.print("maxVertex: {}\n", .{std.mem.max(u32, testMesh.indices)});
    std.debug.print("vertexCount: {}\n", .{testMesh.vertexCount});
    std.debug.print("vertices.len: {}\n", .{testMesh.vertices.len});
    

    mesh_processing.scaleMesh(testMesh, .{.x = 10, .y = 10, .z = 10});
    // mesh.moveMesh(testMesh, .{.x = 300, .y = 300, .z = 300});

    const tmesh = try resource_manager.createMesh("Test", testMesh.vertices, testMesh.indices, 3);
    const model = try resource_manager.createModel("Test");
    const material = try resource_manager.createMaterial("Test", try resource_manager.createColorShader("Test"), .{ 1, 0, 1, 1 }, null);
    try model.addMeshMaterial(tmesh, material);
    const ent = try gameSetup.ecs.createEntity();
    try gameSetup.ecs.addComponent(ent, Model{ .model = model, .visible = true });
    try gameSetup.ecs.addComponent(ent, Transform.identity());

    // =====================
    // === END TEST CODE ===
    // =====================

    // ===== Main Loop ===== //
    while (!gameSetup.window.shouldClose()) {
        // ==== Process Input ==== \\
        const mouse_pos = gameSetup.input.getMousePosition();
        camera_controller.handleMouseMovement(@as(f32, @floatCast(mouse_pos.x)), @as(f32, @floatCast(mouse_pos.y)), 1.0 / 60.0);

        cameraControl(gameSetup.input, &gameSetup.camera);

        if (gameSetup.input.isKeyReleased(.KEY_ESCAPE)) break;

        // ==== Experimental ====
        try testController(gameSetup.input, tmesh, &testMesh, &collapse_err);

        // ==== Render game ====
        gameSetup.renderer.clear();
        try renderSystem(gameSetup.ecs, &gameSetup.camera);

        // ==== Frame logistics ====
        try gameSetup.window.pollEvents();
        gameSetup.window.swapBuffers();
    }
}

const Velocity = struct {
    x: f32,
    y: f32,
    z: f32,
};

const ECSError = error{MapError};
pub fn ecsGeneralComponents(ecs: *ECS) !void {
    try ecs.registerComponent(Model);
    try ecs.registerComponent(Transform);
}

pub fn ecsMap(ecs: *ECS) !void {
    const mapMeshes = MN.MAP_MESHES;
    const mapTextures = MN.MAP_TEXT;
    const mapSize = MN.MAP_SIZE;
    const mapChunking = MN.MAP_CHUNKING;
    const mapCount = mapMeshes.len;

    if (mapTextures.len != mapCount or mapSize.len != mapCount or mapChunking.len != mapCount) {
        std.debug.print("Unequal map parameter-counts\n", .{});
        return ECSError.MapError;
    }

    try ecs.registerDeferedComponent(Map, "deinit");
}

pub fn setActiveMap(ecs: *ECS, mapId: usize, resourceManager: *zune.graphics.ResourceManager, camera: *zune.graphics.Camera) !void {
    if (mapId >= MN.MAP_MESHES.len) {
        std.debug.print("MapId exceeds map count\n", .{});
        return ECSError.MapError;
    }

    const mapName = MN.MAP_NAMES[mapId];
    const mapMeshLoc = MN.MAP_MESHES[mapId];
    const mapTextureLoc = MN.MAP_TEXT[mapId];
    const mapSize = MN.MAP_SIZE[mapId];
    const mapChunking = MN.MAP_CHUNKING[mapId];

    const mapTexture = try resourceManager.createTexture(mapTextureLoc);
    const mapShader = try resourceManager.createTextureShader("dsaiujyh8uiaqewh");
    const mapMaterial = try resourceManager.createMaterial(mapName, mapShader, .{ 1, 1, 1, 0 }, mapTexture);

    const entity = try ecs.createEntity();

    try ecs.addComponent(entity, try Map.init(resourceManager, mapMeshLoc, camera, mapMaterial, mapSize, mapChunking, mapName));
    const id = zmath.Mat4f{.data = math.mat4Identity};
    try ecs.addComponent(entity, Transform{
        .local_matrix = id,
        .world_matrix = id,
    });
}

pub fn cameraControl(input: *zune.core.Input, camera: *zune.graphics.Camera) void {
    var forward = camera.getForwardVector();
    forward.y = 0;
    forward = forward.normalize();
    const side = forward.cross(.{ .x = 0, .y = 1, .z = 0});

    const v: f32 = if (input.isKeyHeld(.KEY_LEFT_CONTROL)) 5.0 else 0.5;

    // Update position
    if (input.isKeyHeld(.KEY_W)) {
        camera.setPosition(camera.position.add(forward.scale(v)));
    }

    if (input.isKeyHeld(.KEY_S)) {
        camera.setPosition(camera.position.add(forward.scale(-v)));
    }

    if (input.isKeyHeld(.KEY_D)) {
        camera.setPosition(camera.position.add(side.scale(v)));
    }

    if (input.isKeyHeld(.KEY_A)) {
        camera.setPosition(camera.position.add(side.scale(-v)));
    }

    if (input.isKeyHeld(.KEY_SPACE)) {
        camera.setPosition(camera.position.add(.{.x = 0, .y = v, .z=0 }));
    }

    if (input.isKeyHeld(.KEY_LEFT_SHIFT)) {
        camera.setPosition(camera.position.add(.{.x = 0, .y = -v, .z = 0  }));
    }
}

pub fn testController(input: *zune.core.Input, m: *Mesh, phMesh: *PlaceHolderMesh, err: *f32) !void {
    var changed = false;
    if(input.isKeyReleased(.KEY_EQUAL)){
        err.* *= 1.2;
        changed = true;
    }

    if(changed){
        try mesh_simplification.collapseMesh(phMesh, err.*);
        try m.updateMesh(phMesh.vertices, phMesh.indices, 3);
    }
}

pub fn renderSystem(ecs: *ECS, camera: *zune.graphics.Camera) !void {
    try renderEntities(ecs, camera);
    try renderMaps(ecs, camera);
}

/// render all `model` components with a `transform` component
fn renderEntities(ecs: *ECS, camera: *zune.graphics.Camera) !void {
    // Query for entities with all required components
    var query = try ecs.query(struct {
        transform: *Transform,
        model: *Model,
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

/// render all `map` components with a `transform` component
fn renderMaps(ecs: *ECS, camera: *zune.graphics.Camera) !void {
    var query = try ecs.query(struct {
        transform: *Transform,
        map: *Map,
    });

    while (try query.next()) |map| {
        try camera.drawModel(
            map.map.model,
            &map.transform.world_matrix,
        );
    }
}

pub fn genCube(resourceManager: *zune.graphics.ResourceManager, camera: zune.graphics.Camera) !*zune.graphics.Model {
    const texture = try resourceManager.createTexture("assets/models/GrassCube/Grass_Block_TEX.png");
    const shader = try resourceManager.createTextureShader();
    const material = try resourceManager.createMaterial("cubemat", shader, .{ 1.0, 1.0, 1.0, 1.0 }, texture);

    const ph_cube_mesh = try util.importPHMeshObj(resourceManager, "assets/models/GrassCube/Grass_Block.obj");
    mesh_processing.scaleMesh(ph_cube_mesh, .{ .x = 1, .y = 1, .z = 1 });
    mesh_processing.moveMesh(ph_cube_mesh, camera.position.subtract(ph_cube_mesh.getBoundingBox().min));
    const cube_mesh = try ph_cube_mesh.toMesh(resourceManager, "dssda", true);
    const cube_model = try resourceManager.createModel("das");
    try cube_model.addMeshMaterial(cube_mesh, material);
    return cube_model;
}

pub fn world2screen(camera: *zune.graphics.Camera, point: math.vec3(f32)) math.vec2(f32) {
    const M = camera.getViewProjectionMatrix().data;
    const v = point;

    const x = M[0] * v.x + M[4] * v.y + M[8] * v.z + M[12];
    const y = M[1] * v.x + M[5] * v.y + M[9] * v.z + M[13];
    // const z = M[2]*v.x + M[6]*v.y + M[10]*v.z + M[14];
    const w = M[3] * v.x + M[7] * v.y + M[11] * v.z + M[15];

    if (w == 0) return .{};

    return .{
        .x = x / w,
        .y = y / w,
    };
}

pub fn inview(camera: *zune.graphics.Camera, point: math.vec3(f32)) bool {
    const pos = world2screen(camera, point);
    return (@abs(pos.x) <= 1 and @abs(pos.y) < 1);
}
