const std = @import("std");
const zune = @import("zune");

const fImport = @import("../mesh/import_files.zig");
const mProc = @import("../mesh/processing.zig");

const Vec2 = zune.math.Vec2;
const Vec3 = zune.math.Vec3;
const Allocator = std.mem.Allocator;
const BoundingBox = mProc.BoundingBox;

pub const MapConfig = struct{
    xsize:f32 = null,
    zsize:f32 = null,
    ysize:f32 = null,
    xchunks:usize = 1,
    zchunks:usize = 1,
};

const Vec2usize = struct{
    x: usize,
    y: usize,
};

fn Vec2_(T: type) type {
    return struct {
        x: T,
        y: T,
    };
}

pub const Map = struct {
    allocator: std.mem.Allocator,
    resourceManager: *zune.graphics.ResourceManager,
    model: *zune.graphics.Model,
    positions: []Vec3,
    boundingBoxes: []BoundingBox,
    
    chunking: Vec2usize,
    chunkSize: Vec2,

    
    pub fn init(resource_manager: *zune.graphics.ResourceManager, objFileLoc: []const u8, material: *zune.graphics.Material, size: Vec3, chunking: Vec2usize, mapName: []const u8) !Map {
        const allocator = resource_manager.allocator;
        
        // ===== load and chunk mesh =====
        var phMapMesh = try fImport.importPHMeshObj(resource_manager, objFileLoc);
        const chunks = try mProc.chunkMesh2Model(resource_manager, &phMapMesh, material, chunking.x, chunking.y, mapName, true);
        const chunkTot = chunks.phMeshes.len;
        defer for (chunks.phMeshes) | phMesh | phMesh.deinit();
        defer allocator.free(chunks);

        // ===== Find chunk positions =====
        const positions = try allocator.alloc(Vec3, chunkTot);
        for (chunks.phMeshes, 0..) | phMesh, i | positions[i] = phMesh.boundingBox.min; 

        // ===== Find chunk BoundingBoxes =====
        const boundingBoxes = try allocator.alloc(BoundingBox, chunkTot);
        for (chunks.phMeshes, 0..) | phMesh, i | boundingBoxes[i] = phMesh.boundingBox;

        return Map{
            .allocator = allocator,
            .resourceManager = resource_manager,
            .model = chunks.model,
            .positions = positions,
            .boundingBoxes = boundingBoxes,
            .chunking = chunking,
            .chunkSize = .{.x = size.x/(@as(f32, @floatFromInt(chunking.x))), .y = size.z/(@as(f32, @floatFromInt(chunking.y)))}
        };
    }

};