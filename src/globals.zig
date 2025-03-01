const std = @import("std");
const zune = @import("zune");

const Vec2 = zune.math.Vec2;
const Vec3 = zune.math.Vec3;

// Window config
pub const WINDOW_WIDTH = 1280;
pub const WINDOW_HEIGHT = 720;
pub const WINDOW_TITLE = "Zune RTS";

// Camera config
pub const CAMERA_FOV: f32 = std.math.degreesToRadians(90.0);
pub const CAMERA_ASPECT: f32 = WINDOW_WIDTH / WINDOW_HEIGHT;
pub const CAMERA_NEAR: f32 = 0.1;
pub const CAMERA_FAR: f32 = 5000;

// Maps
pub const MAP_NAMES = [_][]const u8{
    "Dunes"
};
pub const MAP_MESHES = [_][]const u8{
    "assets/models/Dune/lowresmodel.obj"
};
pub const MAP_TEXT = [_][]const u8{
    "assets/textures/txtr.png"
    // "assets/models/Dune/colormap.png"
};
pub const MAP_CHUNKING = [_]Vec2(usize){
    .{.x = 11, .y = 11},
};
pub const MAP_SIZE = [_]Vec3(f32){
    .{.x = 100.0, .y = 25.0, .z = 100.0}
};