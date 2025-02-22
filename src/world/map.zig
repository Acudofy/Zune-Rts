const std = @import("std");
const zune = @import("zune");

const Allocator = std.mem.Allocator;

pub const MapConfig = struct{
    xsize:f32 = null,
    zsize:f32 = null,
    ysize:f32 = null,
    xchunks:usize = 1,
    zchunks:usize = 1,
};

pub const Map = struct {
    meshes: []zune.graphics.Model,
    // textures: []rl.Texture2D,
    // models: []rl.Model,
    positions: []zune.math.Vec3,
    // transforms: []rl.Matrix,
    // boundingBoxes: []rl.BoundingBox,
    
    chunks_x: usize,
    chunks_y: usize,
    chunk_width: f32,
    chunk_height: f32,

    allocator: std.mem.Allocator,

    // pub fn init(allocator: Allocator, obj_location: []const u8, config: MapConfig) !Map {
    //     // load object

    // }
};