const std = @import("std");

const zune = @import("zune");
const zmath = zune.math;
const Vec3 = zmath.Vec3;

const math = @import("../math.zig");
const MN = @import("../globals.zig");

const Allocator: type = std.mem.Allocator;

/// Unsafe struct, not intended to be called directly
pub const PlaceHolderMesh = struct {
    // Useful to store large amount of indices as it uses u32 instead of u16
    allocator: Allocator,
    indices: []u32 = undefined,
    vertices: []f32 = undefined,
    normals: []f32 = undefined,
    texcoords: []f32 = undefined,
    triangleCount: c_int = undefined,
    vertexCount: c_int = undefined,
    boundingBox: BoundingBox = undefined,

    /// gets a `BoundingBox` type of self.
    pub fn getBoundingBox(self: PlaceHolderMesh) BoundingBox {
        // Get min and max vertex to construct bounds (AABB)
        var minVertex: @Vector(3, f32) = undefined;
        var maxVertex: @Vector(3, f32) = undefined;

        if (self.vertices.len != 0) {
            minVertex = self.vertices[0..3];
            maxVertex = self.vertices[0..3];

            var i: usize = 1;
            while (i < self.vertexCount) : (i += 1) {
                const testVector: @Vector(3, f32) = self.vertices[i * 3 ..][0..3];

                minVertex = @min(minVertex, testVector);
                maxVertex = @max(maxVertex, testVector);
            }
        }

        // Create the bounding box
        const box: BoundingBox = .{
            .min = Vec3{ .x = minVertex[0], .y = minVertex[1], .z = minVertex[2] },
            .max = Vec3{ .x = maxVertex[0], .y = maxVertex[1], .z = maxVertex[2] },
        };

        return box;
    }

    /// Returns a zune.Mesh type, deinits self
    pub fn toMesh(self: *PlaceHolderMesh, resourceManager: *zune.graphics.ResourceManager, meshName: []const u8) !zune.graphics.Mesh {

        // ----- Create rl.Mesh to upload and return -----
        const data = self.interweave();
        const result = try resourceManager.createMesh(meshName, data, self.indices, true);
        self.deinit();
        return result;
    }

    fn interweave(self: PlaceHolderMesh) []f32 {
        const vertexCount = self.vertexCount;
        const b: usize = 8;

        const data = try self.allocator.alloc(f32, vertexCount * b);

        var i: usize = 0;
        while (i < vertexCount) : (i += 1) {
            @memcpy(data[i * b ..][0..3], self.vertices[i * 3 ..][0..3]);
            @memcpy(data[i * b ..][3..5], self.texcoords[i * 2 ..][0..2]);
            @memcpy(data[i * b ..][5..8], self.normals[i * 3 ..][0..3]);
        }

        return data;
    }

    pub fn deinit(self: *PlaceHolderMesh) void {
        // ASSUMES ALL FIELDS HAVE BEEN FILLED
        self.allocator.free(self.indices);
        self.allocator.free(self.vertices);
        self.allocator.free(self.normals);
        self.allocator.free(self.texcoords);
    }
};

/// Holds axis-aligned maximums of points
pub const BoundingBox = struct { min: Vec3, max: Vec3 };
