const std = @import("std");

const zune = @import("zune");
const zmath = zune.math;

const math = @import("../math.zig");
const MN = @import("../globals.zig");
const Vec3 = math.vec3;

const Allocator: type = std.mem.Allocator;
const OfMeshName = @import("import_files.zig").OfMeshName;

// ======================================
// Error definition and type declations
// ======================================

const MeshError = error{
    NoFacesInMesh,
    InvalidDimensions,
    TooManyVertices,
    Unexpected,
};

const avec3 = @Vector(3, f32);
const avec4 = @Vector(4, f32);
const HalfMatLen = 10;
const ErrorMatrix = [HalfMatLen]f64; // row major generally (last 2 indices unused)

// ======================================
// Public functions
// ======================================

/// move all `mesh` vertices +`dist`
pub fn moveMesh(mesh: PlaceHolderMesh, dist: Vec3(f32)) void {
    // Alters mesh vertices dist from original spot
    var i: usize = 0;
    while (i < mesh.vertexCount) : (i += 1) {
        mesh.vertices[i * 3] += dist.x;
        mesh.vertices[i * 3 + 1] += dist.y;
        mesh.vertices[i * 3 + 2] += dist.z;
    }
}

pub fn scaleMesh(mesh: PlaceHolderMesh, scaling: Vec3(f32)) void {
    var i: usize = 0;
    while (i < mesh.vertexCount) : (i += 1) {
        mesh.vertices[i * 3] *= scaling.x;
        mesh.vertices[i * 3 + 1] *= scaling.y;
        mesh.vertices[i * 3 + 2] *= scaling.z;
    }
}

/// Place `mesh` minimum at (0, 0, 0)
pub fn zeroMesh(mesh: PlaceHolderMesh) void {
    const BB = mesh.getBoundingBox();
    moveMesh(mesh, BB.min.inv());
}

/// Generate equispaced chunks from `mesh` according amount specified in `XChunks` and `YChunks`
/// if `keepPH`, will not deinit intermediate created placeholder Meshes. if set to false, pointers will be invalid
/// Deinits provided `mesh`.
pub fn chunkMesh(resourceManager: *zune.graphics.ResourceManager, mesh: *PlaceHolderMesh, chunkName: []const u8, XChunks: usize, ZChunks: usize, keepPH: bool) !struct { meshes: []*zune.graphics.Mesh, phMeshes: []PlaceHolderMesh } {
    const allocator = resourceManager.allocator;

    // ===== Ensure valid boundingBox in mesh =====
    mesh.boundingBox = mesh.getBoundingBox();

    // ===== Creat constants in variant types =====
    const totChunks: usize = XChunks * ZChunks;

    // ===== Start Mesh array =====
    var meshes = try allocator.alloc(PlaceHolderMesh, totChunks);
    meshes[0] = mesh.*; // Store value inside array

    // ===== Create x-axis strips =====
    const stripMeshes = try chopChopMesh(allocator, meshes[0], ZChunks, .{ .z = 1 });
    defer allocator.free(stripMeshes);

    // ===== Split strips into chunks and store =====
    for (stripMeshes, 0..) |strip, i| {
        const chunks = try chopChopMesh(allocator, strip, XChunks, .{ .x = 1 });
        @memcpy(meshes[i * XChunks ..][0..XChunks], chunks);
        allocator.free(chunks);
    }

    // ===== Convert meshes to zMeshes =====
    const result: []*zune.graphics.Mesh = try allocator.alloc(*zune.graphics.Mesh, totChunks);
    for (0..totChunks) |i| {
        result[i] = try meshes[i].toMesh(resourceManager, .{ .meshPrefix = chunkName }, !keepPH);
    }

    // ===== Free memory =====
    if (!keepPH) allocator.free(meshes);

    // ===== Return =====
    return .{
        .meshes = result,
        .phMeshes = meshes,
    };
}

/// wrapper around `chunkMesh` but returns a model which contains all meshes as well as the PlaceHolderMeshes for further processing.
pub fn chunkMesh2Model(resourceManager: *zune.graphics.ResourceManager, mesh: *PlaceHolderMesh, material: *zune.graphics.Material, XChunks: usize, ZChunks: usize, modelName: []const u8, keepPH: bool) !struct { model: *zune.graphics.Model, phMeshes: []PlaceHolderMesh } {
    const allocator = resourceManager.allocator;

    const chunks = try chunkMesh(resourceManager, mesh, modelName, XChunks, ZChunks, keepPH);
    var model = try resourceManager.createModel(modelName);

    defer allocator.free(chunks.meshes);

    for (chunks.meshes) |chunk| {
        try model.addMeshMaterial(chunk, material);
    }

    return .{ .model = model, .phMeshes = chunks.phMeshes };
}

// ======================================
// Private functions
// ======================================

/// Split mesh in N strips along cardinal 'dir' axis: This implies the axis orthogonal to `dir` axis remains intact
fn chopChopMesh(allocator: Allocator, mesh: PlaceHolderMesh, N: usize, dir: Vec3(f32)) ![]PlaceHolderMesh {
    // ===== Initialize variables =====
    const axis: Vec3(f32) = if (dir.x > dir.z) .{ .x = 1 } else .{ .z = 1 };
    const meshes = try allocator.alloc(PlaceHolderMesh, N);
    meshes[0] = mesh;
    const worth = try allocator.alloc(usize, N);
    for (0..N) |i| worth[i] = 0;
    worth[0] = N;

    defer allocator.free(worth);

    var maxWorth = std.mem.max(usize, worth);
    var debug: usize = 1;
    while (maxWorth != 1) : (debug += 1) {

        // ----- Find index of largest chunk -----
        const i = std.mem.indexOfScalar(usize, worth, maxWorth) orelse worth.len;

        // ----- Determine ratio in split -----
        const splitWorth = @divFloor(maxWorth, 2);
        const ratio = @as(f32, @floatFromInt(splitWorth)) / @as(f32, @floatFromInt(maxWorth));

        // ----- Split mesh & store -----
        const splitMeshes = try ratioSplitMesh(allocator, meshes[i], ratio, axis);

        meshes[i] = splitMeshes[0];
        meshes[i + splitWorth] = splitMeshes[1];

        // ----- Update worths -----
        worth[i] = splitWorth;
        worth[i + splitWorth] = maxWorth - splitWorth;

        // ----- Update maxWorth -----
        maxWorth = std.mem.max(usize, worth);
    }
    return meshes;
}

/// Thin wrapper around `splitMesh` to split based on a ratio along `dir`. Cuts orthogonal to direction.
/// Assumes `mesh.boundingBox` exists, and dir is axis-bound: either y=1 or z=1
fn ratioSplitMesh(allocator: Allocator, mesh: PlaceHolderMesh, ratio: f32, dir: Vec3(f32)) ![2]PlaceHolderMesh {
    if (ratio < 0 or 1 <= ratio) return MeshError.InvalidDimensions;

    const meshSize = mesh.boundingBox.max.subtract(mesh.boundingBox.min);

    return switch (dir.x == 1) {
        true => try splitMesh(allocator, mesh, .{ .x = ratio * meshSize.x + mesh.boundingBox.min.x }, .{ .z = -1.0 }),
        false => try splitMesh(allocator, mesh, .{ .z = ratio * meshSize.z + mesh.boundingBox.min.z }, .{ .x = 1.0 }),
    };
}

/// Split phMesh into 2 seperate placeholder meshes, cutting from `point` along `dir`
/// left of `dir` is first mesh, right of `dir` is other.
/// Deinitializes provided mesh
pub fn splitMesh(allocator: Allocator, mesh: PlaceHolderMesh, point: Vec3(f32), dir: Vec3(f32)) ![2]PlaceHolderMesh {
    const TotVertexCount: u32 = mesh.vertexCount;
    const TotTriangleCount: u32 = mesh.triangleCount;

    const orth_dir = (Vec3(f32){ .y = 1 }).cross(dir);

    // Continue initializing vertices
    const vertice1 = try allocator.alloc(f32, TotVertexCount * 3);
    errdefer allocator.free(vertice1);
    var p1: u32 = 0;
    const vertice2 = try allocator.alloc(f32, TotVertexCount * 3);
    errdefer allocator.free(vertice2);
    var p2: u32 = 0;

    const UV1 = try allocator.alloc(f32, TotVertexCount * 2);
    errdefer allocator.free(UV1);
    const UV2 = try allocator.alloc(f32, TotVertexCount * 2);
    errdefer allocator.free(UV2);

    const normal1 = try allocator.alloc(f32, TotVertexCount * 3);
    errdefer allocator.free(normal1);
    const normal2 = try allocator.alloc(f32, TotVertexCount * 3);
    errdefer allocator.free(normal2);

    const ids1: []u32 = try allocator.alloc(u32, TotVertexCount);
    errdefer allocator.free(ids1);
    const ids2: []u32 = try allocator.alloc(u32, TotVertexCount);
    errdefer allocator.free(ids2);

    // Bounding box variable to keep track of
    var BBmin1: Vec3(f32) = .{ .x = 999999.9, .y = 999999.9, .z = 999999.9 };
    var BBmax1: Vec3(f32) = .{ .x = -999999.9, .y = -999999.9, .z = -999999.9 };
    var BBmin2: Vec3(f32) = .{ .x = 999999.9, .y = 999999.9, .z = 999999.9 };
    var BBmax2: Vec3(f32) = .{ .x = -999999.9, .y = -999999.9, .z = -999999.9 };

    // Split mesh in 2
    var i: u32 = 0;
    while (i < TotVertexCount) : (i += 1) {
        const v_loc = Vec3(f32){ .x = mesh.vertices[i * 3] - point.x, .y = mesh.vertices[i * 3 + 1] - point.y, .z = mesh.vertices[i * 3 + 2] - point.z };
        if (v_loc.dot(orth_dir) > 0) { // > 0 = 1 side, <= 0 is other
            vertice1[p1 * 3] = mesh.vertices[i * 3];
            vertice1[p1 * 3 + 1] = mesh.vertices[i * 3 + 1];
            vertice1[p1 * 3 + 2] = mesh.vertices[i * 3 + 2];

            BBmin1 = math.vec3Min(BBmin1, .{ .x = vertice1[p1 * 3], .y = vertice1[p1 * 3 + 1], .z = vertice1[p1 * 3 + 2] });
            BBmax1 = math.vec3Max(BBmax1, .{ .x = vertice1[p1 * 3], .y = vertice1[p1 * 3 + 1], .z = vertice1[p1 * 3 + 2] });

            normal1[p1 * 3] = mesh.normals[i * 3];
            normal1[p1 * 3 + 1] = mesh.normals[i * 3 + 1];
            normal1[p1 * 3 + 2] = mesh.normals[i * 3 + 2];

            UV1[p1 * 2] = mesh.texcoords[i * 2];
            UV1[p1 * 2 + 1] = mesh.texcoords[i * 2 + 1];

            ids1[i] = p1;

            p1 += 1;
        } else {
            vertice2[p2 * 3] = mesh.vertices[i * 3];
            vertice2[p2 * 3 + 1] = mesh.vertices[i * 3 + 1];
            vertice2[p2 * 3 + 2] = mesh.vertices[i * 3 + 2];

            BBmin2 = math.vec3Min(BBmin2, .{ .x = vertice2[p2 * 3], .y = vertice2[p2 * 3 + 1], .z = vertice2[p2 * 3 + 2] });
            BBmax2 = math.vec3Max(BBmax2, .{ .x = vertice2[p2 * 3], .y = vertice2[p2 * 3 + 1], .z = vertice2[p2 * 3 + 2] });

            normal2[p2 * 3] = mesh.normals[i * 3];
            normal2[p2 * 3 + 1] = mesh.normals[i * 3 + 1];
            normal2[p2 * 3 + 2] = mesh.normals[i * 3 + 2];

            UV2[p2 * 2] = mesh.texcoords[i * 2];
            UV2[p2 * 2 + 1] = mesh.texcoords[i * 2 + 1];

            ids2[i] = p2;
            ids1[i] = TotVertexCount;

            p2 += 1;
        }
    }
    const chunk1Vertices = p1;
    const chunk2Vertices = p2;

    // Refactor indices such that all vertices with an index below n belong to chunk 1 and all vertices above n fall within chunk 2
    const connection_mask1: []bool = try allocator.alloc(bool, TotTriangleCount); // Used to keep track of which faces belong to chunk 1
    errdefer allocator.free(connection_mask1);
    const connection_mask2: []bool = try allocator.alloc(bool, TotTriangleCount); // Used to keep track of which faces belong to chunk 2
    errdefer allocator.free(connection_mask2);
    const other_vertex_offset: []u2 = try allocator.alloc(u2, TotTriangleCount); // Used to keep track which singular vertice falls in the other chunk | vertex 0 -> vertex 1 and 2 fall inside other chunk etc.
    errdefer allocator.free(other_vertex_offset);

    const editable_indices = try allocator.alloc(u32, TotTriangleCount * 3);
    errdefer allocator.free(editable_indices);

    @memcpy(editable_indices, mesh.indices[0 .. TotTriangleCount * 3]);

    i = 0;
    while (i < ids1.len) : (i += 1) {
        if (ids1[i] == TotVertexCount) ids1[i] = ids2[i] + chunk1Vertices;
    } // Merge the 2 id lists, offsetting the ids in chunk 2 with the last id in id1

    i = 0; // replace indices to seperate chunk 1 & 2
    while (i < editable_indices.len) : (i += 1) {
        editable_indices[i] = ids1[editable_indices[i]];
    }

    // Seperate connections (indices) into chunk 1, 2, or neither
    i = 0;
    p1 = 0; // Now storing number of faces in chunk 1
    p2 = 0;
    while (i < TotTriangleCount) : (i += 1) {
        const vecEditable_indice: @Vector(3, @TypeOf(editable_indices[0])) = editable_indices[i * 3 ..][0..3].*;
        const vecCompare_values: @TypeOf(vecEditable_indice) = @splat(chunk1Vertices);
        const bs: @Vector(3, bool) = vecEditable_indice < vecCompare_values;
        // const b1 = editable_indices[i * 3] < chunk1Vertices;
        // const b2 = editable_indices[i * 3 + 1] < chunk1Vertices;
        // const b3 = editable_indices[i * 3 + 2] < chunk1Vertices;

        if (@reduce(.And, bs)) { // If all vertices of triangle fall within chunk 1
            connection_mask1[i] = true;
            p1 += 1;
        } else if (!@reduce(.Or, bs)) { // If it all falls within chunk 2
            connection_mask2[i] = true;
            p2 += 1;
        } else {
            // std.debug.print("b1: {}\nb2: {}\nb3: {}\nchunk1Vertices: {}\n", .{b1, b2, b3, chunk1Vertices});
            other_vertex_offset[i] = switch (bs[0]) {
                true => // b1 is true
                switch (bs[1]) {
                    true => @as(u2, 2), // b2 is also true
                    false => switch (bs[2]) {
                        true => @as(u2, 1),
                        false => @as(u2, 0),
                    }, // b2 = false -> b3 determines minority
                },
                false => // b1 is false
                switch (bs[1]) {
                    false => @as(u2, 2),
                    true => switch (bs[2]) {
                        false => @as(u2, 1),
                        true => @as(u2, 0),
                    },
                },
            };
            // find3bool([_]bool{ b1, b2, b3 }, !((b1 and b2) or (b2 and b3) or (b3 and b1))); // Search for bool index in minority state -> if any (bx and bx) -> 2 vertices in chunk 1 -> look for vertice in chunk 2 (false)
            // std.debug.print("Other vertex offset: {}\n", .{other_vertex_offset[i]});
        }
    }

    // store faces into respective indices and divide up ambiguous faces between the 2 chunks
    const indice1 = try allocator.alloc(u32, (TotTriangleCount - p2) * 3); // p1 = amount of faces in chunk 1 -> total-p2 = amount of possible faces in chunk 1 (including edge-faces)
    errdefer allocator.free(indice1);
    // std.debug.print("TotTriangleCount - p1 = {} - {} = {}\n", .{TotTriangleCount, p1, TotTriangleCount - p1});
    const indice2 = try allocator.alloc(u32, (TotTriangleCount - p1) * 3); // Same for p2 and chunk 2
    errdefer allocator.free(indice2);

    var added_vertices1: u32 = 0; // Keep track of added vertices
    var added_vertices2: u32 = 0;

    i = 0;
    p1 = 0;
    p2 = 0;
    while (i < TotTriangleCount) : (i += 1) {
        if (connection_mask1[i]) {
            indice1[p1 * 3] = editable_indices[i * 3];
            indice1[p1 * 3 + 1] = editable_indices[i * 3 + 1];
            indice1[p1 * 3 + 2] = editable_indices[i * 3 + 2];
            p1 += 1;
        } else if (connection_mask2[i]) {
            indice2[p2 * 3] = editable_indices[i * 3] - chunk1Vertices; // First index of chunk 2 is p1+1 -> should be changed to 0
            indice2[p2 * 3 + 1] = editable_indices[i * 3 + 1] - chunk1Vertices;
            indice2[p2 * 3 + 2] = editable_indices[i * 3 + 2] - chunk1Vertices;
            p2 += 1;
        } else {
            const minorityIndiceOffset = other_vertex_offset[i]; // returns indice of vertex within face which is in 'other chunk' (0..3)
            const OtherVertexInd: u32 = editable_indices[i * 3 + @as(u32, @intCast(minorityIndiceOffset))]; // returns index of vertex which is *alone* in 'other' chunk (0..mesh.vertices.len) | Need usize cast to be able to reach desired indice values
            if (OtherVertexInd >= chunk1Vertices) { // minority vertex belongs to chunk 2 -> most vertices fall in chunk 1
                const indexOfOtherInVertex2 = OtherVertexInd - chunk1Vertices; // Correct for offset (n) in total vertex indices (-= n)
                // Create new vertex for face to attach to
                vertice1[(chunk1Vertices + added_vertices1) * 3] = vertice2[indexOfOtherInVertex2 * 3];
                vertice1[(chunk1Vertices + added_vertices1) * 3 + 1] = vertice2[indexOfOtherInVertex2 * 3 + 1];
                vertice1[(chunk1Vertices + added_vertices1) * 3 + 2] = vertice2[indexOfOtherInVertex2 * 3 + 2];

                // Check added vertice for boundingbox
                BBmin1 = math.vec3Min(BBmin1, .{ .x = vertice1[(chunk1Vertices + added_vertices1) * 3], .y = vertice1[(chunk1Vertices + added_vertices1) * 3 + 1], .z = vertice1[(chunk1Vertices + added_vertices1) * 3 + 2] });
                BBmax1 = math.vec3Max(BBmax1, .{ .x = vertice1[(chunk1Vertices + added_vertices1) * 3], .y = vertice1[(chunk1Vertices + added_vertices1) * 3 + 1], .z = vertice1[(chunk1Vertices + added_vertices1) * 3 + 2] });

                // Create new normal for created vertex
                normal1[(chunk1Vertices + added_vertices1) * 3] = normal2[indexOfOtherInVertex2 * 3];
                normal1[(chunk1Vertices + added_vertices1) * 3 + 1] = normal2[indexOfOtherInVertex2 * 3 + 1];
                normal1[(chunk1Vertices + added_vertices1) * 3 + 2] = normal2[indexOfOtherInVertex2 * 3 + 2];

                // Create new UVs for created vertex
                UV1[(chunk1Vertices + added_vertices1) * 2] = UV2[indexOfOtherInVertex2 * 2];
                UV1[(chunk1Vertices + added_vertices1) * 2 + 1] = UV2[indexOfOtherInVertex2 * 2 + 1];

                // Add face to indices
                indice1[p1 * 3] = if (minorityIndiceOffset != 0) editable_indices[i * 3] else chunk1Vertices + added_vertices1; // Use normal index unless it is the index of the newly created vertex
                indice1[p1 * 3 + 1] = if (minorityIndiceOffset != 1) editable_indices[i * 3 + 1] else chunk1Vertices + added_vertices1;
                indice1[p1 * 3 + 2] = if (minorityIndiceOffset != 2) editable_indices[i * 3 + 2] else chunk1Vertices + added_vertices1;

                added_vertices1 += 1;
                p1 += 1;
            } else { // minority vertex belongs in chunk 1 -> most vertices fall in chunk 2
                const indexOfOtherInVertex1 = OtherVertexInd;
                // Create new vertex for face to attach to
                vertice2[(chunk2Vertices + added_vertices2) * 3] = vertice1[indexOfOtherInVertex1 * 3]; // @as(usize, @intCast(
                vertice2[(chunk2Vertices + added_vertices2) * 3 + 1] = vertice1[indexOfOtherInVertex1 * 3 + 1];
                vertice2[(chunk2Vertices + added_vertices2) * 3 + 2] = vertice1[indexOfOtherInVertex1 * 3 + 2];

                // Check added vertice for boundingbox
                BBmin2 = math.vec3Min(BBmin2, .{ .x = vertice2[(chunk2Vertices + added_vertices2) * 3], .y = vertice2[(chunk2Vertices + added_vertices2) * 3 + 1], .z = vertice2[(chunk2Vertices + added_vertices2) * 3 + 2] });
                BBmax2 = math.vec3Max(BBmax2, .{ .x = vertice2[(chunk2Vertices + added_vertices2) * 3], .y = vertice2[(chunk2Vertices + added_vertices2) * 3 + 1], .z = vertice2[(chunk2Vertices + added_vertices2) * 3 + 2] });

                // Create new normal for created vertex
                normal2[(chunk2Vertices + added_vertices2) * 3] = normal1[indexOfOtherInVertex1 * 3];
                normal2[(chunk2Vertices + added_vertices2) * 3 + 1] = normal1[indexOfOtherInVertex1 * 3 + 1];
                normal2[(chunk2Vertices + added_vertices2) * 3 + 2] = normal1[indexOfOtherInVertex1 * 3 + 2];

                // Create new UVs for created vertex
                UV2[(chunk2Vertices + added_vertices2) * 2] = UV1[indexOfOtherInVertex1 * 2];
                UV2[(chunk2Vertices + added_vertices2) * 2 + 1] = UV1[indexOfOtherInVertex1 * 2 + 1];

                // Add face to indices
                indice2[p2 * 3] = if (minorityIndiceOffset != 0) editable_indices[i * 3] - chunk1Vertices else chunk2Vertices + added_vertices2; // Use normal index unless it is the index of the newly created vertex
                indice2[p2 * 3 + 1] = if (minorityIndiceOffset != 1) editable_indices[i * 3 + 1] - chunk1Vertices else chunk2Vertices + added_vertices2;
                indice2[p2 * 3 + 2] = if (minorityIndiceOffset != 2) editable_indices[i * 3 + 2] - chunk1Vertices else chunk2Vertices + added_vertices2;

                added_vertices2 += 1;
                p2 += 1;
            }
        }
    }

    const chunk1_Vertices: u32 = chunk1Vertices + added_vertices1;
    const chunk2_Vertices: u32 = chunk2Vertices + added_vertices2;

    // Check validity of meshes
    // Return errors if a mesh has 0 faces to render -> will return an error on freeing memory (I think? solved some other errors which might be related so maybe not anymore)
    if (p1 == 0 or p2 == 0) { // Check if meshes will have enough triangles
        return MeshError.NoFacesInMesh;
        // IF CUT SHOULD BE WITHIN MESH BOUNDS -> TRY ROTATING CUTTING DIRECTION
    }

    // Trimming memory to correct size
    const vertices1 = try allocator.realloc(vertice1, chunk1_Vertices * 3);
    const vertices2 = try allocator.realloc(vertice2, chunk2_Vertices * 3);

    const indices1 = try allocator.realloc(indice1, p1 * 3);
    const indices2 = try allocator.realloc(indice2, p2 * 3);

    const normals1 = try allocator.realloc(normal1, chunk1_Vertices * 3);
    const normals2 = try allocator.realloc(normal2, chunk2_Vertices * 3);

    const UVs1 = try allocator.realloc(UV1, chunk1_Vertices * 2);
    const UVs2 = try allocator.realloc(UV2, chunk2_Vertices * 2);

    // Construct meshes
    const meshes: [2]PlaceHolderMesh = .{
        PlaceHolderMesh{
            .allocator = allocator,
            .triangleCount = p1,
            .indices = indices1,
            .vertexCount = chunk1_Vertices,
            .vertices = vertices1,
            .texcoords = UVs1,
            .normals = normals1,
            .boundingBox = BoundingBox{ .min = BBmin1, .max = BBmax1 },
        },
        PlaceHolderMesh{
            .allocator = allocator,
            .triangleCount = p2,
            .indices = indices2,
            .vertexCount = chunk2_Vertices,
            .vertices = vertices2,
            .texcoords = UVs2,
            .normals = normals2,
            .boundingBox = BoundingBox{ .min = BBmin2, .max = BBmax2 },
        },
    };

    // Free up memory
    allocator.free(connection_mask1);
    allocator.free(connection_mask2);
    allocator.free(other_vertex_offset);
    allocator.free(editable_indices);
    allocator.free(ids1);
    allocator.free(ids2);
    mesh.deinit();

    return meshes;
}

// ======================================
// Mesh simplification functions
// ======================================

pub fn collapseMesh(mesh: *PlaceHolderMesh, err_threshold: f32) !void {

    // ===== Create halfEdge mesh =====
    var halfEdges = try HalfEdges.fromPHMesh(mesh);
    defer halfEdges.deinit();
    try halfEdges.collapseMesh(err_threshold);
}

/// Returns the index of an item with `itemPtr` in an array given a pointer to the first item in said array `basePtr`.
pub inline fn indexOfPtr(comptime T: type, basePtr: *T, itemPtr: *T) usize {
    return (@intFromPtr(itemPtr)-@intFromPtr(basePtr))/@sizeOf(T);
}

// ======================================
// Structs
// ======================================

const HalfEdgeError = error{  TooManyNeighbours, 
                                    NotEnoughNeighbours, 
                                    NoQuadricErrors, 
                                    NoEdgeErrors, 
                                    FaceFlip,
                                    DetachedVertex};

/// Struct to store raw mesh data in halfEdge structure
pub const HalfEdges = struct {
    allocator: Allocator,
    mesh: *PlaceHolderMesh,
    HE: []HalfEdge,

    buffer1: std.ArrayList(*HalfEdge),
    buffer2: std.ArrayList(*HalfEdge),
    i_reader: u32 = 0,

    indices: []u32, // shared with mesh
    indexBuffer1: std.ArrayList(u32),
    indexBuffer2: std.ArrayList(u32),
    faceNormals: []f32, // owned
    normalBuffer1: std.ArrayList(FaceNormalInfo),
    normalBuffer2: std.ArrayList(FaceNormalInfo),

    vertices: []f32, // shared with mesh
    quadricError: ?[]ErrorMatrix = null,
    edgeErrors: ?[]EdgeErrInfo = null,
    alteredErrorsBuffer: std.ArrayList(AlteredEdgeErrorInfo),

    edge: u32 = 0,

    pub fn fromPHMesh(mesh: *PlaceHolderMesh) !HalfEdges {
        // ===== Retrieve required info =====
        const allocator = mesh.allocator;
        const triangleCount = mesh.triangleCount;
        const indices = mesh.indices;
        const vertices = mesh.vertices;
        
        // ===== Find face normals =====
        const faceNormals = try getFaceNormals(allocator, vertices, indices);

        // std.debug.print("vertexCount: {}\n", .{@divExact(vertices.len, 3)});

        // ===== Create storage =====
        var halfEdges = try allocator.alloc(HalfEdge, 3 * triangleCount); // Needs more capacity for boundary twins //try std.ArrayList(HalfEdge).initCapacity(allocator, 3*triangleCount);
        var twinless = try allocator.alloc(bool, 3 * triangleCount);
        defer allocator.free(twinless);
        var twinnedCount: u32 = 0;
        for (0..twinless.len) |i| twinless[i] = true;
        var links = std.AutoHashMap([2]u32, u32).init(allocator);
        defer links.deinit();
        try links.ensureTotalCapacity(4 * @as(u32, @intCast(triangleCount))); // add 3*triangles actual capacity -> ensure more empty space

        // ===== Go trough all triangles =====
        var i: u32 = 0; // go trough triangles in mesh
        while (i < triangleCount * 3) : (i += 3) {
            var j: u32 = 0; // count of edge in triangle
            while (j < 3) : (j += 1) {
                const currInd = i + j; // Stores halfEdge index
                const nextInd = i + @mod(j + 1, 3);
                const prevInd = i + @mod(j + 3 - 1, 3);

                // ----- Fill in known information
                halfEdges[currInd].origin = indices[currInd];
                halfEdges[currInd].next = nextInd;
                halfEdges[currInd].prev = prevInd;
                halfEdges[currInd].i_face = i;

                // ----- Store links -----
                const vCurr = indices[currInd];
                const vNext = indices[nextInd];
                const linkNext: [2]u32 = if (vCurr < vNext) .{ vCurr, vNext } else .{ vNext, vCurr }; // Ensure small to large ordering

                // std.debug.print("linkNext({}): {any}\n", .{i+j, linkNext});

                if (links.fetchPutAssumeCapacity(linkNext, currInd)) |twin| {
                    // std.debug.print("TwinFound\n", .{});
                    // ----- Fill in twin fields for both -----
                    const twinInd = twin.value;
                    // std.debug.print("twinPairs[{}]: {}/{}\n", .{i+j, currInd, twinInd});

                    halfEdges[currInd].twin = twinInd;
                    halfEdges[twinInd].twin = currInd;

                    twinless[currInd] = false;
                    twinless[twinInd] = false;

                    twinnedCount += 2;
                }
            }
        }
        // std.debug.print("linksCount/triangleCount*3: {}/{}\n", .{links.count(), triangleCount*3});
        // for (halfEdges, 0..) | he, ind | std.debug.print("[{}]: {any}\n", .{ind, he});
        // ===== Create border twins =====
        const HE_start: u32 = @intCast(halfEdges.len);
        // std.debug.print("HE_start: {}\n", .{HE_start});
        const edgeCount: u32 = HE_start+(HE_start-twinnedCount); // total + (edges - edges with twins) = total + twinless edges
        const halfEdges_ext: []HalfEdge = try allocator.realloc(halfEdges, edgeCount); 
        // const border_ext: []bool = try allocator.realloc(border, edgeCount);

        var j: u32 = 0;
        for (twinless, 0..) |b, n| {
            if (!b) continue; // skip if has twin
            const pos: u32 = @intCast(n);
            // std.debug.print("pos: {}\n", .{pos});

            // ----- next HalfEdge element in original -----
            const nextHE: HalfEdge = halfEdges_ext[halfEdges_ext[pos].next];

            // ----- determine if next element of border exists -----
            var i_leadingInnerBorder = halfEdges_ext[pos].prev; // counter clockwise over root until next twinless edge is found (or faceless edge i.e. complete border)
            while(!twinless[i_leadingInnerBorder]){ // if leadingInnerBorder is twinless i.e. is an edge of the mesh
                if(halfEdges_ext[halfEdges_ext[i_leadingInnerBorder].twin].i_face == null) break; // If outer border is encountered -> Border exists
                i_leadingInnerBorder = halfEdges_ext[halfEdges_ext[i_leadingInnerBorder].twin].prev; // Move to next potential inner border
            }
            const nextBorderExists = !twinless[i_leadingInnerBorder];

            // ----- determine if previous element of border exists -----
            var i_nextInnerBorder = halfEdges_ext[pos].next; // counter clockwise over root until next twinless edge is found (or faceless edge i.e. complete border)
            while(!twinless[i_nextInnerBorder]){ // if nextBorderTwin_pos is edgeless
                if(halfEdges_ext[halfEdges_ext[i_nextInnerBorder].twin].i_face == null) break; // If outer border is encountered -> Border exists
                i_nextInnerBorder = halfEdges_ext[halfEdges_ext[i_nextInnerBorder].twin].next; // Move to next potential inner border
            }
            const prevBorderExists = !twinless[i_nextInnerBorder];

            // while (!twinless[i_leadingInnerBorder]) : (i_leadingInnerBorder = halfEdges_ext[halfEdges_ext[i_leadingInnerBorder].prev].twin) { // while not at undefined border -> check next possible border
            //     if (halfEdges_ext[halfEdges_ext[i_leadingInnerBorder].twin].i_face != null) break; // if not undefined border -> Check if is defined border -> if so also valid position
            // }
            
            // const symetryEdge: HalfEdge = halfEdges_ext[halfEdges_ext[pos].prev];
            // const flipped_symetryEdge: HalfEdge = halfEdges_ext[symetryEdge.twin];
            // const nextBorderTwin_pos = flipped_symetryEdge.prev;


            // ----- create halfEdge -----
            const i_new = HE_start + j;

            halfEdges_ext[i_new] = HalfEdge{
                .origin = nextHE.origin,
                .twin = pos,
                .next = if(nextBorderExists) halfEdges_ext[i_leadingInnerBorder].twin else undefined,
                .prev = if(prevBorderExists) halfEdges_ext[i_nextInnerBorder].twin else undefined, // Previous border should be found out 
                .i_face = null,
            };
            halfEdges_ext[pos].twin = i_new;
            twinless[pos] = false;
            
            if(nextBorderExists) halfEdges_ext[halfEdges_ext[i_leadingInnerBorder].twin].prev = i_new;
            if(prevBorderExists) halfEdges_ext[halfEdges_ext[i_nextInnerBorder].twin].next = i_new;
            
            j+=1;

            // if (twinless[i_leadingInnerBorder]) { // if next border is not yet made
            //     halfEdges_ext[i_new] = HalfEdge{ // add edge to current border with previous next border is unknown
            //         .origin = nextHE.origin,
            //         .twin = pos,
            //         .next = i_new + 1,
            //         .prev = if (i > 0) i_new - 1 else undefined, // Previous border should be found out 
            //         .i_face = null,
            //     };
            //     twinless[i_leadingInnerBorder] = false; // border is created
            //     twinless[n] = false;
            // } else { // if next border section already exists
            //     const i_next_border = halfEdges_ext[i_leadingInnerBorder].twin;
            //     halfEdges_ext[i_new] = HalfEdge{
            //         .origin = nextHE.origin,
            //         .twin = pos,
            //         .next = i_next_border,
            //         .prev = i_new - 1,
            //         .i_face = null,
            //     };
            //     halfEdges_ext[i_next_border].prev = i_new;
            // }
            // halfEdges_ext[pos].twin = i_new;
            // twinless[pos] = false;

            // j += 1;
        }

        // ===== TODO: Add face index =====

        // ===== Return halfEdge data struct =====
        return .{
            .allocator = allocator,
            .mesh = mesh,
            .HE = halfEdges_ext,
            .buffer1 = try std.ArrayList(*HalfEdge).initCapacity(allocator, 32),
            .buffer2 = try std.ArrayList(*HalfEdge).initCapacity(allocator, 32),
            .vertices = vertices,
            .indexBuffer1 = try std.ArrayList(u32).initCapacity(allocator, 30),
            .indexBuffer2 = try std.ArrayList(u32).initCapacity(allocator, 30),
            .faceNormals = faceNormals,
            .normalBuffer1 = try std.ArrayList(FaceNormalInfo).initCapacity(allocator, 30),
            .normalBuffer2 = try std.ArrayList(FaceNormalInfo).initCapacity(allocator, 30),
            .indices = indices,

            .alteredErrorsBuffer = try std.ArrayList(AlteredEdgeErrorInfo).initCapacity(allocator, 32),
        };
    }

    pub fn deinit(self: HalfEdges) void {
        const allocator=  self.allocator;
        
        allocator.free(self.HE);
        allocator.free(self.faceNormals);

        if (self.quadricError) |err| allocator.free(err);
        if (self.edgeErrors) |err| allocator.free(err);

        self.buffer1.deinit();
        self.buffer2.deinit();

        self.indexBuffer1.deinit();
        self.indexBuffer2.deinit();
        
        self.normalBuffer1.deinit();
        self.normalBuffer2.deinit();

        self.alteredErrorsBuffer.deinit();
    }

    /// Rotate `edge` counter-clockwise around vertex at root of `edge`
    pub inline fn rotCCW(self: *HalfEdges) void {
        self.edge = self.HE[self.HE[self.edge].prev].twin;
    }

    /// Rotate `edge` counter-clockwise around vertex at end of `edge`
    pub inline fn rotEndCCW(self: *HalfEdges) void {
        self.edge = self.HE[self.HE[self.edge].twin].prev;
    }

    /// Rotate `edge` clockwise around vertex at root of `edge`
    pub inline fn rotCW(self: *HalfEdges) void {
        self.edge = self.HE[self.HE[self.edge].twin].next;
    }

    /// Rotate `edge` clockwise around vertex at end of `edge`
    pub inline fn rotEndCW(self: *HalfEdges) void {
        self.edge = self.HE[self.HE[self.edge].next].twin;
    }

    pub inline fn flip(self: *HalfEdges) void {
        self.edge = self.HE[self.edge].twin;
    }

    pub inline fn next(self: *HalfEdges) void {
        self.edge = self.HE[self.edge].next;
    } 

    pub inline fn previous(self: *HalfEdges) void {
        self.edge = self.HE[self.edge].prev;
    } 

    /// return pointer to `HalfEdge` belonging to `self.edge`
    pub inline fn getHalfEdge(self: HalfEdges) *HalfEdge {
        return &self.HE[self.edge];
    }

    /// Collapse mesh until errThreshold. Alters `self.edge` and `self.mesh`.
    pub fn collapseMesh(self: *HalfEdges, errThreshold: f32) !void {
        const allocator = self.allocator;
        
        // ===== Create edge errors =====
        if (self.quadricError == null) try self.addErrorMatrices(10.0);

        if (self.edgeErrors == null) try self.addEdgeErrorsList();
        const edgeErrors = self.edgeErrors.?;
        

        // printEdgeHeader();
        // for([_]usize{2268, 2271, 3893, 2279, 2277, 2280, 2281, 2282, 2275, 2276, 2269, 2270, 2265, 2266, 2267, 2262, 2263, 3890, 3888, 3889, 3894, 2256, 2259, 2261, 2260, 2284, 2285, 2280, 2281, 2282, 2277}) |edge| self.printEdge(edge);

        // ===== Create linkedErrors list =====
        var LE = try LinkedErrors.fromEdgeErrors(allocator, edgeErrors, errThreshold);
        defer LE.deinit();

        var debug: u32 = 0;
        var onlyErrors: bool = false;
        while(!onlyErrors):(LE.resetStart()){
            onlyErrors = true;
            var chainExists = true;

            while(LE.getEdgeIndexWithLowestError()) | edge |{
                self.edge = edge;
                var EndOfChain = false;
                std.debug.print("error of edge[{}] ({}): {}/{}\n", .{edge, LE.inChain(edge), LE.edgeErrors[edge].err, errThreshold});
                if(self.edgeErrors.?[edge].err >= errThreshold) return error.Unexpected;

                // ===== Collapse edge =====
                // if(!LE.inChain(2271)) return error.Unexpected;
                // try LE.chainCheck(self.HE); // Check chain integrity

                // std.debug.print("\n---------------------------------------------\n", .{});
                // std.debug.print("collapsing edge({}): {}\n", .{debug, self.edge});


                self.collapseEdge() catch | err | switch (err) {
                    HalfEdgeError.FaceFlip, HalfEdgeError.DetachedVertex, HalfEdgeError.NotEnoughNeighbours, HalfEdgeError.TooManyNeighbours => {
                        // std.debug.print("Error: {any}\n", .{err});
                        try LE.moveStartUp();
                        continue;
                    },
                    else => return err,
                };
                onlyErrors = false; // something collapsed while iterating over edges

                // ===== Propegate edge collapse in linkedErrors =====
                // ----- re-order halfEdges -----
                try LE.reevaluateEntries(self.alteredErrorsBuffer.items); // remove try -> remove try from LLspot

                // ----- remove deleted edges ------
                const removeEdge1 = self.edge;
                const removeEdge2 = self.getHalfEdge().twin;

                LE.removeFaceOfEdge(removeEdge1, self.HE) catch | err | switch (err) {
                    LinkedErrorsErrors.EndOfChain=> { // LE.linkStart has reached end of chain -> Try to reset
                        EndOfChain = true;
                    },
                    LinkedErrorsErrors.EmptyChain => chainExists = false, // No more edges in chain link
                    LinkedErrorsErrors.AllItemsExceedError => chainExists = false, // No more collapsable edges
                    else => return err, // Unexpected error
                };
                LE.removeFaceOfEdge(removeEdge2, self.HE) catch | err | switch (err) {
                    LinkedErrorsErrors.EndOfChain=> { // LE.linkStart has reached end of chain -> Try to reset
                        EndOfChain = true;
                    },
                    LinkedErrorsErrors.EmptyChain => chainExists = false, // No more edges in chain link
                    LinkedErrorsErrors.AllItemsExceedError => chainExists = false, // No more collapsable edges
                    else => return err, // Unexpected error
                };

                debug += 1;

                if(EndOfChain or !chainExists) break; // end of chain has been reached by start -> reset start
            }

            if(!chainExists) break; // If all edges in linkedErrors have collapsed 
        }

        // ===== Alter placeholder mesh according to LinkedErrors =====
        // std.debug.print("Alter PHMesh:\n", .{});
        try LE.updateToPHMesh(self.HE, self.mesh);

        
    }

    /// Modify self to collapse edge, stores alteredEdgeErrInfo in `self.alteredErrorsBuffer`
    pub fn collapseEdge(self: *HalfEdges) !void {
        const d = false; // self.edge == 2281;
        if(d){
            std.debug.print("edge[{}]: {any}\n", .{2268, self.HE[2268]});
            std.debug.print("edge[{}]: {any}\n", .{2271, self.HE[2271]});
        }

        const currEdge = self.edge;
        const edgeBase = &self.HE[0];

        // ===== Check needed field =====
        if (self.quadricError == null) return HalfEdgeError.NoQuadricErrors;
        if (self.edgeErrors == null) return HalfEdgeError.NoEdgeErrors;

        // ===== Fetch mutual neighbours in buffers =====
        const commonNeighbourTuple = try self.fetchCommonNeighbours();
        const onBound = commonNeighbourTuple.onBoundary;
        const twinEdges = commonNeighbourTuple.edgesFromMSV;

        if(d) std.debug.print("twinEdges[0]: ({}, {})\n", .{indexOfPtr(HalfEdge, edgeBase, twinEdges[0][0]), indexOfPtr(HalfEdge, edgeBase, twinEdges[0][1])});
        if(d) std.debug.print("twinEdges[1]: ({}, {})\n", .{indexOfPtr(HalfEdge, edgeBase, twinEdges[1][0]), indexOfPtr(HalfEdge, edgeBase, twinEdges[1][1])});

        if(d) {
            printEdgeHeader();
            self.printEdgeWithOrigin(self.HE[2280].origin);
            // for([_]usize{2298, 2301, 3897, 2299, 2300, 2298, 2322} ) | edge | self.printEdge(edge);
            // for([_]usize{2281, 2303, 2277, 2268, 2301, 2324, 2271, 2298, 2282, 2324, 2279, 2299, 2256, 2257, 2323, 3888, 3890, 3891, 3893, 3892, 3899, 3905, 3904, 3903, 3902, 2321, 2300, 2299} ) | edge | self.printEdge(edge);
            std.debug.print("\n", .{});
            var i:usize = 3895;
            while(i != 3897):(i = self.HE[i].next){
                self.printEdge(i);
            }
            // // for([_]usize{3895, 3897} ) | edge | self.printEdge(edge);
        }

        // ===== Merge vertex origins =====
        // Remove vertex with higher index
        // std.debug.print("Merging vertices...\n", .{});
        const smallest = self.HE[currEdge].origin < self.HE[self.HE[currEdge].twin].origin; // vertex at root of currEdge has smaller index than vertex and end of currEdge
        const bufferWithRemovedOrigin = switch (smallest) {
            true => self.buffer2, // halfEdges towards end of currEdge
            false => self.buffer1, // halfEdges towards root of currEdge
        };
        // std.debug.print("OriginPair: {}/{}\n", .{self.HE[currEdge].origin, self.HE[self.HE[currEdge].twin].origin});
        const mergedOrigin = switch (smallest) {
            true => self.HE[currEdge].origin,
            false => self.HE[self.HE[currEdge].twin].origin,
        };
        const removedOrigin = switch (smallest) {
            true => self.HE[self.HE[currEdge].twin].origin,
            false => self.HE[currEdge].origin,
        };

        for (bufferWithRemovedOrigin.items) | item| { // Change larger origin index to smaller origin index 
            // std.debug.print("Change origin {} -> {}\n", .{self.HE[item.twin].origin, mergedOrigin});
            // if(mergedOrigin == 19) return error.Unexpected;
            self.HE[item.twin].origin = mergedOrigin;
        }

        const V_mergedOrigin_old = self.vertices[mergedOrigin * 3 ..][0..3].*;
        // std.debug.print("V_old:\n", .{});
        // printVector(V_mergedOrigin_old);

        // ----- replace vertex position of merged origin -----
        // std.debug.print("edgeError:\n", .{});
        // std.debug.print("{d:<9.5}\n", .{self.edgeErrors.?[currEdge].err});
        // std.debug.print("edge:\n", .{});
        // std.debug.print("{d}\n", .{currEdge});
        @memcpy(self.vertices[mergedOrigin * 3 ..][0..3], &self.edgeErrors.?[currEdge].newPos);

        // ===== Set self.indices =====
        if (onBound) return error.Unexpected;
        // std.debug.print("Modifying indices(1)...\n", .{});
        self.modifyIndices(&self.normalBuffer1, &self.indexBuffer1, mergedOrigin, removedOrigin) catch |err| {
            // std.debug.print("Restoring collapse(1)...\n", .{});
            self.edge = currEdge;
            @memcpy(self.vertices[mergedOrigin*3..][0..3], &V_mergedOrigin_old);
            try self.restoreCollapse(onBound, null, removedOrigin, true, false);
            return err;
        };
        if(d){
            std.debug.print("edge[{}]: {any}\n", .{2268, self.HE[2268]});
            std.debug.print("edge[{}]: {any}\n", .{2271, self.HE[2271]});
        }

        self.flip();
        // std.debug.print("Modifying indices(2)...\n", .{});
        self.modifyIndices(&self.normalBuffer2, &self.indexBuffer2, mergedOrigin, removedOrigin) catch |err| {
            self.edge = currEdge;
            @memcpy(self.vertices[mergedOrigin*3..][0..3], &V_mergedOrigin_old); // Restore vertex position
            try self.restoreCollapse(onBound, null, removedOrigin, true, true); // restore the rest
            return err;
        };

        if(d){
            std.debug.print("edge[{}]: {any}\n", .{2268, self.HE[2268]});
            std.debug.print("edge[{}]: {any}\n", .{2271, self.HE[2271]});
        }
        
        // ===== Alter twins =====
        // std.debug.print("Altering twins...\n", .{});
        // - Store original twin values for restoration
        // - Check if outside-twins have a face -> If not, mutual neighbouring face (MNF) will collapse to single line

        const collapsingFaces: [2]u32 = .{ self.HE[self.edge].i_face orelse std.math.maxInt(u32), self.HE[self.HE[self.edge].twin].i_face orelse std.math.maxInt(u32) }; // neighbouring faces of collapsing edge
        var twinInfos: [2]CollapsingFaceTwins = .{undefined, undefined};
        // std.debug.print("{any}\n", .{twinEdges});
        var i:usize = 0;
        while(i<twinEdges.len):(i+=1){
        // for (twinEdges[0..], 0..) | *twinEdge, i| {
            const twinEdge = twinEdges[i];
            if (onBound and i == 1) continue; // for boundary edge -> only 1 neighbouring face

            // ----- for edges check if they are on MNF -----
            if (twinEdge[0].i_face == collapsingFaces[0] or twinEdge[0].i_face == collapsingFaces[1]) { // first twinEdge is on MNF -> Second edge is outside of MNF

                // ----- Store original edge pairs -----
                twinInfos[i] = .{
                    .outer1 = twinEdge[0].twin,
                    .inner1 = @intCast(indexOfPtr(HalfEdge, edgeBase, twinEdge[0])),
                    .inner2 = twinEdge[1].twin,
                    .outer2 = @intCast(indexOfPtr(HalfEdge, edgeBase, twinEdge[1])),
                };
                if(d) std.debug.print("twinInfos[{}]: {any}\n", .{i, twinInfos[i]});
            } else { // second twinEdge is inside shared face
                // ----- Store original edge pairs -----
                twinInfos[i] = .{
                    .outer1 = @intCast(indexOfPtr(HalfEdge, edgeBase, twinEdge[0])),
                    .inner1 = twinEdge[0].twin,
                    .inner2 = @intCast(indexOfPtr(HalfEdge, edgeBase, twinEdge[1])),
                    .outer2 = twinEdge[1].twin,
                };
                if(d) std.debug.print("twinInfos[{}]: {any}\n", .{i, twinInfos[i]});
            }

            // ----- make edges outside of MNF 'skip' MNF -----
            const i_out1 = twinInfos[i].outer1; // Index of edges outside of shared face
            const i_out2 = twinInfos[i].outer2;
            self.HE[i_out1].twin = i_out2;
            self.HE[i_out2].twin = i_out1;
        }

        // if(d) std.debug.print("twinInfos: {any}\n", .{twinInfos});

        // ===== Verify if MSF are still valid =====
        // Condition for validity is that shared faces should adjoint at least 1 additional face 
        for (twinInfos) | tInfo | {
            if (self.HE[tInfo.outer1].i_face == null and self.HE[tInfo.outer2].i_face == null){
                self.edge = currEdge;
                @memcpy(self.vertices[mergedOrigin*3..][0..3], &V_mergedOrigin_old);
                try self.restoreCollapse(onBound, twinInfos, removedOrigin, true, true);
                return HalfEdgeError.DetachedVertex; // Vertex has single connecting edge but no neighbouring faces
            }
        }

        if(d){
            std.debug.print("edge[{}]: {any}\n", .{2268, self.HE[2268]});
            std.debug.print("edge[{}]: {any}\n", .{2271, self.HE[2271]});
        }


        // ===== Merge quadric error =====
        // std.debug.print("Merging quadric errors\n", .{});
        const qe1 = &self.quadricError.?[mergedOrigin];
        const qe2 = &self.quadricError.?[removedOrigin];
        
        qe1[0] += qe2[0];
        qe1[1] += qe2[1];
        qe1[2] += qe2[2];
        qe1[3] += qe2[3];
        qe1[4] += qe2[4];
        qe1[5] += qe2[5];
        qe1[6] += qe2[6];
        qe1[7] += qe2[7];
        qe1[8] += qe2[8];
        qe1[9] += qe2[9];

        // ===== Update new edge-collapse errors =====
        // std.debug.print("Construct new error values\n", .{});
        self.alteredErrorsBuffer.clearRetainingCapacity();

        // std.debug.print("collapsingEdge:", .{});
        for ([2][]*HalfEdge{self.buffer1.items, self.buffer2.items}) | inwardsEdges | { // TODO: self.buffer contains collapsing edge & twin -> Should be excluded & taken out of 
            for (inwardsEdges) | edge | {
                // ----- set self.edge to to-be-altered edge -----
                self.edge = @intCast(indexOfPtr(HalfEdge, edgeBase, edge));
                
                // ----- check if edge is on collapsing face -----
                const edgeFace = self.getHalfEdge().i_face;
                const removedEdge = (edgeFace == collapsingFaces[0] or edgeFace == collapsingFaces[1]); // edge is on collapsing face
                const doNotCheckTwin = switch(onBound) {
                    false => self.onTwinInfoOuters(twinInfos[0]) or self.onTwinInfoOuters(twinInfos[1]), // results in double check between buffer1 (vertex at root of self.edge) and buffer 2 (vertex at end of self.edge)
                    true => self.onTwinInfoOuters(twinInfos[0]),
                };

                if (!removedEdge){ // if edge is not on collapsing face
                    // std.debug.print("update edge {}\n", .{self.edge});
                    const ee = try self.getEdgeError();
                    // std.debug.print("edgeError: {any}\n", .{ee});
                    const toBeAlteredEdgeError = AlteredEdgeErrorInfo{
                        .index = self.edge,
                        .edgeErrorInfo = ee,
                    };
                    try self.alteredErrorsBuffer.append(toBeAlteredEdgeError);
                }


                // std.debug.print("toBeAlteredEdgeError:\n{any}\n", .{toBeAlteredEdgeError});


                // ----- store updated info on inwards edge -----
                self.flip();
                const twinFace = self.getHalfEdge().i_face;
                const removedTwinEdge = (twinFace == collapsingFaces[0] or twinFace == collapsingFaces[1]); // edge is on collapsing face

                if(doNotCheckTwin or removedTwinEdge) continue; // if edge is on collapsing face or causes double update -> do not try to alter

                // std.debug.print("update edge {}\n", .{self.edge});
                try self.alteredErrorsBuffer.append(AlteredEdgeErrorInfo{
                    .index = self.edge,
                    .edgeErrorInfo = try self.getEdgeError(),
                });
            }
        }

        if(d){
            std.debug.print("edge[{}]: {any}\n", .{2268, self.HE[2268]});
            std.debug.print("edge[{}]: {any}\n", .{2271, self.HE[2271]});
        }

        self.edge = currEdge;
    }

    /// Checks if edge is on outer 
    fn onTwinInfoOuters(self: HalfEdges, twinInfo: CollapsingFaceTwins) bool {
        if(self.edge == twinInfo.outer1 or self.edge == twinInfo.outer2) return true;
        return false;
    }

    /// Sets `self.edgeErrors`. Same ordering as `self.HE`
    pub fn addEdgeErrorsList(self: *HalfEdges) !void {
        const allocator = self.allocator;
        const edgeCount = self.HE.len;
        const currEdge = self.edge;

        const edgeErrors = try allocator.alloc(EdgeErrInfo, edgeCount);

        var i:u32 = 0;
        while(i<edgeCount):(i+=1){
            self.edge = i;
            edgeErrors[i] = try self.getEdgeError();
        }

        // std.mem.sortUnstable(EdgeErrInfo, edgeErrors, {}, errInfoCompare);

        self.edgeErrors = edgeErrors;
        self.edge = currEdge;
    }

    // Options:
    // - Convert to f64 hope that that works
    // - Use linear interpolation for best spot between 2 vertices -> Create errors when not singular
    // - Use system solver instead of pseudo Inverse -> Error is positive semi-definite -> Use gradient descent or something

    /// Get error of vertex if you collapse current vertex
    pub fn getEdgeError(self: HalfEdges) !EdgeErrInfo {
        if (self.quadricError == null) return HalfEdgeError.NoQuadricErrors;

        const i_1 = self.HE[self.edge].origin;
        const i_2 = self.HE[self.HE[self.edge].twin].origin;

        const qe1 = self.quadricError.?[i_1];
        const qe2 = self.quadricError.?[i_2];

        // ===== Create inversing matrix =====
        const m: [16]f64 = .{
            qe1[0] + qe2[0], qe1[1] + qe2[1], qe1[2] + qe2[2], 0, //qe1[3] + qe2[3], // IDK if column or row major -> Symetric so should be fine
            qe1[1] + qe2[1], qe1[4] + qe2[4], qe1[5] + qe2[5], 0, //qe1[6] + qe2[6],
            qe1[2] + qe2[2], qe1[5] + qe2[5], qe1[7] + qe2[7], 0, //qe1[8] + qe2[8],
            qe1[3] + qe2[3], qe1[6] + qe2[6], qe1[8] + qe2[8], 1, //qe1[9] + qe2[9],
        };

        // ===== Create testing matrix ======
        const t: [16]f64 = .{ m[0], m[1], m[2], qe1[3] + qe2[3],
                            m[4], m[5], m[6], qe1[6] + qe2[6],
                            m[8], m[9], m[10], qe1[8] + qe2[8],
                            m[12], m[13], m[14], qe1[9] + qe2[9]};

        var M:[16]f64 = undefined;
        math.eigen_mat4d_robust_inverse(&m, &M);

        var v_optimal: [4]f64 = M[12..16].*;  

        var rowVector: [4]f64 = undefined;
        math.eigen_vec4d_multiply(&t, &v_optimal, &rowVector);

        const err_value: f64 = rowVector[0] * v_optimal[0] + rowVector[1] * v_optimal[1] + rowVector[2] * v_optimal[2] + rowVector[3] * v_optimal[3];
        if(@abs(err_value)<5*std.math.pow(f32, 10, -6)){ // Precision error -> round to full values
            return .{.err = 0, .newPos = .{@floatCast(v_optimal[0]), @floatCast(v_optimal[1]), @floatCast(v_optimal[2])}};
        }

        if(err_value < 0){
            return .{.err = 0, .newPos = .{@floatCast(v_optimal[0]), @floatCast(v_optimal[1]), @floatCast(v_optimal[2])}};
        }

        // if(err_value < 0) {
        //     std.debug.print("error value: {}\n", .{err_value});
        //     std.debug.print("From matrix (m):\n", .{});
        //     print_CM_4Matd(m);
        //     std.debug.print("\ninverse(m):\n", .{});
        //     print_CM_4Matd(M);
        //     std.debug.print("\ntest matrix(t):\n", .{});
        //     print_CM_4Matd(t);

        //     std.debug.print("\nv_optimal:\n", .{});
        //     for(v_optimal) | v | {
        //         print_66_f64(v);
        //         std.debug.print("\n", .{});
        //     }

        //     std.debug.print("\nt*v_optimal:\n", .{});
        //     for(rowVector) | v | {
        //         print_66_f64(v);
        //         std.debug.print("\n", .{});
        //     }

        //     std.debug.print("\nt[0]*v_optimal[0] + t[4]*v_optimal[1] + t[8]*v_optimal[2] + t[12]*v_optimal[3]\n", .{});
        //     std.debug.print("------- Precise -------\n", .{});
        //     for([4][2]f64{.{t[0], v_optimal[0]}, .{t[4], v_optimal[1]}, .{t[8],v_optimal[2]}, .{t[12],v_optimal[3]}}, 0..) | tv, k | {
        //         print_66_f64(tv[0]);
        //         std.debug.print(" * ", .{});
        //         print_66_f64(tv[1]);
        //         if (k!=3) std.debug.print(" + ", .{});
        //     }
        //     std.debug.print(" = \n", .{});

        //     for([_]f64{t[0]*v_optimal[0], t[4]*v_optimal[1], t[8]*v_optimal[2], t[12]*v_optimal[3]}, 0..) | v, k | {
        //         print_66_f64(v);
        //         if (k!=3) std.debug.print(" + ", .{});
        //     }
        //     std.debug.print(" = \n", .{});

        //     const row1_value: f64 = t[0]*v_optimal[0] + t[4]*v_optimal[1] + t[8]*v_optimal[2] + t[12]*v_optimal[3]; 
        //     print_66_f64(row1_value);
        //     std.debug.print("\n\n", .{});
            
        //     std.debug.print("------- Rounded -------\n", .{});
        //     const precision: f64 = 9;
        //     const rounded_values = [_]f64{  math.roundTo(f64, t[0], precision), math.roundTo(f64, v_optimal[0], precision),  
        //                                             math.roundTo(f64, t[4], precision), math.roundTo(f64, v_optimal[1], precision), 
        //                                             math.roundTo(f64, t[8], precision),math.roundTo(f64, v_optimal[2], precision), 
        //                                             math.roundTo(f64, t[12], precision),math.roundTo(f64, v_optimal[3], precision)};
            
        //     for(0..@divExact(rounded_values.len,2)) | i | {
        //         std.debug.print("{d} * {d}", .{rounded_values[i*2], rounded_values[i*2+1]});
        //         if(i != 3) std.debug.print(" + ", .{});
        //     }
        //     std.debug.print(" =\n", .{});

        //     for(0..@divExact(rounded_values.len,2)) | i | {
        //         const v = rounded_values[i*2] * rounded_values[i*2+1];
        //         print_66_f64(v);
        //         if(i != 3) std.debug.print(" + ", .{});
        //     }
        //     std.debug.print(" =\n", .{});

        //     const rounded_value = rounded_values[0]*rounded_values[1] + rounded_values[2]*rounded_values[3] + rounded_values[4]*rounded_values[5] + rounded_values[6]*rounded_values[7];
        //     print_66_f64(rounded_value);
        //     std.debug.print("\n\n", .{});

        //     return error.Unexpected;
        // }

        return .{.err = @floatCast(err_value), .newPos = .{@floatCast(v_optimal[0]), @floatCast(v_optimal[1]), @floatCast(v_optimal[2])}};
    }

    /// Provided information of altered parts in memory, restores self to before collapse
    /// Resets altered twins if `twinInfo` != `null`
    /// 
    /// Resets normals from `self.normalBuffer1`, and resets `self.indices` from `self.indexBuffer1` if `has_changed_indices_1` is `true`.
    /// Requires `removedOrigin` to be non-`null` values.
    /// 
    /// Resets normals from `self.normalBuffer2`, and resets `self.indices` from `self.indexBuffer1` if `has_changed_indices_2` is `true`.
    /// Requires `removedOrigin` to be non-`null` values. 
    fn restoreCollapse(self: HalfEdges, onBoundary: bool, twinInfos: ?[2]CollapsingFaceTwins, removedOrigin: ?u32, has_changed_indices_1: bool, has_changed_indices_2: bool) !void {
        
        if (twinInfos) | twinInfo | {
            const edges = self.HE;
            for (twinInfo, 0..) | twins, i | {
                if (onBoundary and i == 1) continue; // if onboundary -> Only 1 neighbouring face i.e. 1 set of twins
                
                // if (twins.inner1 == twins.outer1 or twins.inner2 == twins.outer2) {
                //     // std.debug.print("\n\n============ INVALID TWINS ================\n{any}\n====================================\n\n", .{twins});
                // }
                edges[twins.inner1].twin = twins.outer1;
                edges[twins.outer1].twin = twins.inner1;
                edges[twins.inner2].twin = twins.outer2;
                edges[twins.outer2].twin = twins.inner2;
            }
        }

        if (has_changed_indices_1 or has_changed_indices_2){
            if (removedOrigin == null) return error.InvalidDataType; // removeOrigin is required value

            const smaller = self.HE[self.edge].origin < self.HE[self.HE[self.edge].twin].origin;
            const replacedOriginEdgeBuffer = if(smaller) self.buffer2 else self.buffer1;
            for (replacedOriginEdgeBuffer.items) | item | {
                self.HE[item.twin].origin = removedOrigin.?;
            }
            const collapsedEdge = if(smaller) self.HE[self.edge].twin else self.edge;
            self.HE[collapsedEdge].origin = removedOrigin.?;
        }

        if (has_changed_indices_1) {
            if (removedOrigin == null) return error.InvalidDataType; // removeOrigin is required value

            const normals = self.faceNormals;
            const indices = self.indices;
            
            for (self.normalBuffer1.items) | normalInfo | {
                @memcpy(normals[normalInfo.i_face..][0..3], &normalInfo.normal);
            }
            for (self.indexBuffer1.items) | ind | {
                indices[ind] = removedOrigin.?;
            }
        }
        
        if (has_changed_indices_2) {
            if (removedOrigin == null) return error.InvalidDataType;

            const normals = self.faceNormals;
            const indices = self.indices;
            
            for (self.normalBuffer2.items) | normalInfo | {
                @memcpy(normals[normalInfo.i_face..][0..3], &normalInfo.normal);
            }
            for (self.indexBuffer2.items) | ind | {
                indices[ind] = removedOrigin.?;
            }
        }
    }

    /// For all faces adjointing vertex at base of `self.edge`, replace `removedVertex` from `self.indices` to `mergedVertex`.
    /// Replaces normals in `self.faceNormals` with new orientation.
    /// 
    /// Stores old normals in `normalBuffer`, and the indices inside which `self.indices` which were changed in `indexBuffer`
    /// 
    /// If face flips, return an error
    fn modifyIndices(self: *HalfEdges, normalBuffer: *std.ArrayList(FaceNormalInfo), replacedIndicesBuffer: *std.ArrayList(u32), mergedVertex: u32, removedVertex: u32) !void {
        normalBuffer.clearRetainingCapacity();
        replacedIndicesBuffer.clearRetainingCapacity();
        
        const currEdge = self.edge;
        const faceNormals = self.faceNormals;
        const vertices = self.vertices;
        const indices = self.indices;

        // ===== Check faces at base =====
        const leftFace = self.HE[self.edge].i_face orelse self.HE[self.HE[self.edge].twin].i_face.?; // faces adjacent to collapsing edge (assumes edge has at least 1 adjacent face)
        const rightFace = self.HE[self.HE[self.edge].twin].i_face orelse leftFace;

        self.rotCCW();
        while (self.edge != currEdge) : (self.rotCCW()) {
            // for (self.HE[0..45], 0..) | edge, i | std.debug.print("HE[{}]: {any}\n", .{i, edge});
            // std.debug.print("self.edge: {}/{}\n", .{self.edge, currEdge});
            // std.debug.print("HE[{}]: {any}\n", .{self.edge, self.HE[self.edge]});            
            // if (self.edge == 303) return error.Unexpected;
            // if (self.edge != currEdge) return error.Unexpected;
            const i_currFace = self.HE[self.edge].i_face orelse continue; // if face does not exist -> check next face

            if (i_currFace == leftFace or i_currFace == rightFace) continue; // Skip faces adjacent to collapsing edge

            // std.debug.print("faceNormals.len: {}\n currFace: {}\n", .{faceNormals.len, i_currFace});
            const norm_old = faceNormals[i_currFace ..][0..3];

            const currIndices = indices[i_currFace ..][0..3];
            if(std.mem.indexOfScalar(u32, currIndices, removedVertex)) | pos | {
                // std.debug.print("face: {} != {}/{}\n", .{i_currFace, leftFace, rightFace});
                // std.debug.print("RemovedVertex: {}\n", .{removedVertex});
                // std.debug.print("currIndices: {any}\n", .{currIndices});
                // std.debug.print("indiceChange in edge indices[{}]: {} -> {}\n", .{i_currFace+pos, currIndices[pos], mergedVertex});
                currIndices[pos] = mergedVertex; // May make invalid face for collapsing faces due to collapsing edge origin and end becoming the same origin 
                try replacedIndicesBuffer.append(i_currFace+@as(u32, @intCast(pos)));
            }

            const a = currIndices[0];
            const b = currIndices[1];
            const c = currIndices[2];

            const v1 = vertices[a * 3 ..][0..3].*;
            const v2 = vertices[b * 3 ..][0..3].*;
            const v3 = vertices[c * 3 ..][0..3].*;

            const norm_new = math.getVec3Normal(v1, v2, v3);

            const dotProduct = norm_old[0] * norm_new[0] + norm_old[1] * norm_new[1] + norm_old[2] * norm_new[2];

            if (dotProduct < 0) { // if new and old  normal directions are opposed
                // std.debug.print("normal_old:\n", .{});
                // printVector(norm_old.*);
                // std.debug.print("normal_new:\n", .{});
                // printVector(norm_new);
                
                // std.debug.print("dotProduct: {}\n", .{dotProduct});
                
                self.edge = currEdge;
                // std.debug.print("Face:\n", .{});
                // std.debug.print("({d:<30}, {d:<30}, {d:<30})\n", .{currIndices[0], currIndices[1], currIndices[2]});
                // printFace(v1, v2, v3);

                return HalfEdgeError.FaceFlip;
            } else {
                const normalInfo = FaceNormalInfo{
                    .normal = norm_new,
                    .i_face = i_currFace,
                };
                try normalBuffer.append(normalInfo); // Store slice
            }
        }

        self.edge = currEdge;
    }

    /// Get `halfEdge`s from shared neighbouring vertices towards start and end vertices of `self.edge`.
    /// First entree in edge-pairs ([2]*Halfedges) points to base of `self.edge`, second entree points to vertex at end of `self.edge`
    /// 
    /// Sets `self.buffer1` to store all HalfEdges pointing to vertex at base of `self.edge`. Similarly `self.buffer2` stores all HalfEdges pointing to vertex at end of `self.edge`.
    /// Both exclude `self.edge` and its twin.
    pub fn fetchCommonNeighbours(self: *HalfEdges) !struct {edgesFromMSV: [2][2]*HalfEdge, onBoundary: bool} {
        const currEdge = self.edge;

        // if(currEdge == 2264 or currEdge == 2261 or currEdge == 2265 or currEdge == 2267) std.debug.print("collapsing edge: {}\n", .{currEdge});
        
        // std.debug.print("Fetching Neighbours...\n", .{});
        const boundary1 = self.HE[self.edge].i_face == null;
        try self.fetchNeighbours(&self.buffer1, true);
        self.flip();
        const boundary2 = self.HE[self.edge].i_face == null;
        try self.fetchNeighbours(&self.buffer2, true);
        self.edge = currEdge; // revert to original edge position

        const onBound = boundary1 and boundary2; // edge only aligned to 1 face

        var twinEdge1: [2]*HalfEdge = undefined; // Store halfedges from common neighbouring vertex to start and end of collapsing edge
        var twinEdge2: [2]*HalfEdge = undefined;

        // ===== Store mutual neighbours =====
        var n_count: u32 = 0; // shared neighbours count
        const n_desired:u32 = switch (onBound) {true => 1, false => 2};

        // std.debug.print("self.buffer2.items: {any}\n", .{self.buffer2.items});
        for (self.buffer1.items) | item | {
            if (getIndexOfVertex(self.buffer2.items, item.origin)) |pos| { // check for item of buffer 1 of the vertex is also found in buffer2
                // std.debug.print("item.origin: {}\n", .{item.origin});
                switch (n_count) {
                    0 => {
                        twinEdge1 = .{ item, self.buffer2.items[pos]};
                        if (onBound) break; // if on boundary -> only 1 face
                        },
                    1 => twinEdge2 = .{ item, self.buffer2.items[pos] },
                    else => return HalfEdgeError.TooManyNeighbours,
                }
                n_count += 1;
            }
        }
        if (n_count < n_desired) return HalfEdgeError.NotEnoughNeighbours;

        const twinEdges: [2][2]*HalfEdge = switch (onBound) {
            true => .{[2]*HalfEdge{twinEdge1[0], twinEdge1[1]}, undefined},
            false => .{[2]*HalfEdge{twinEdge1[0], twinEdge1[1]}, [2]*HalfEdge{twinEdge2[0], twinEdge2[1]}},
        };

        return .{.edgesFromMSV = twinEdges, .onBoundary = onBound};
    }

    /// Clears `self.buffer` and stores `HalfEdges` which point to root vertex of `self.edge`
    pub fn fetchNeighbours(self: *HalfEdges, buffer: *std.ArrayList(*HalfEdge), exclude_first: bool) !void {
        const currEdge = self.edge;
        // std.debug.print("currEdge: {}\n", .{currEdge});


        // ===== Clear buffer =====
        buffer.clearRetainingCapacity();

        // ===== Store edges around current vertex =====
        // ----- set first 2 neighbours -----
        self.flip(); // First edge pointing to vertex at root of currEdge
        // std.debug.print("self.edge.twin: {}\n", .{self.edge});


        const p = false; // self.edge == 3894;
        // if(p){
        //     printEdgeHeader();
        //     var e = self.getHalfEdge().next;
        //     self.printEdge(self.edge);
        //     self.printEdge(self.getHalfEdge().twin);

        //     while(e != self.edge):(e = self.HE[e].next){
        //         std.debug.print("\n", .{});
        //         self.printEdge(e);
        //         self.printEdge(self.HE[e].twin);
        //     }
        // }

        if (exclude_first and p) std.debug.print("buf[-1]: {}/{} {?}\n", .{self.edge, self.HE.len, self.getHalfEdge().i_face});
        if (exclude_first) self.rotEndCCW(); // skip first edge
        if(p) std.debug.print("buf[0]: {}\n", .{self.edge});
        // if(p) self.printEdge(self.edge);

        buffer.appendAssumeCapacity(self.getHalfEdge()); // first neighbour
        self.rotEndCCW(); // Next edge pointing to vertex at root of currEdge
        if(p) std.debug.print("buf[1]: {}\n", .{self.edge});
        // if(p) self.printEdge(self.edge);

        buffer.appendAssumeCapacity(self.getHalfEdge()); // second neighbour

        // ----- Find remaining neighbours -----
        var debug:u32 = 1;
        while (buffer.getLast() != buffer.items[0]) { // not looped back yet
            // std.debug.print("{}|", .{buffer.getLast().});
            debug += 1;
            if (p and debug>10) return error.Unexpected;
            self.rotEndCCW(); // next edge
            if(p) std.debug.print("buf[{}]: {}\n", .{debug, self.edge});
            // if(p) self.printEdge(self.edge);
            const he = self.getHalfEdge();
            try buffer.append(he);
        }
        // if(p) std.debug.print("\n", .{});

        _ = buffer.pop(); // remove duplicate
        if (exclude_first) _ = buffer.pop(); // exclude self.edge <- second to last edge in list

        // ===== Restore self =====
        self.edge = currEdge;
    }

    /// Returns index of halfedge in array with origin `vertex`
    fn getIndexOfVertex(array: []*HalfEdge, vertex: u32) ?u32 {
        const bufferSize = array.len;
        var i: u32 = 0;
        while (i + 3 < bufferSize) : (i += 4) { // check only full loads
            const load: @Vector(4, u32) = .{ array[i].origin, array[i + 1].origin, array[i + 2].origin, array[i + 3].origin };
            if (std.simd.firstIndexOfValue(load, vertex)) |ind| {
                return i + ind;
            }
        }
        while (i < bufferSize) : (i += 1) { // do not-full loads manually
            if (array[i].origin == vertex) {
                return i;
            }
        }
        return null;
    }

    /// `buffersize` is count of halfEdges stored in buffer
    fn indexOfVertexInBuffer(self: HalfEdges, vertex: u32) ?usize {
        const bufferSize = self.buffer.items.len;
        var i = &self.i_reader;
        while (i + 3 < bufferSize) : (i += 4) { // check only full loads
            const load: @Vector(4, u32) = .{ self.buffer.items[i].origin, self.buffer.items[i + 1].origin, self.buffer.items[i + 2].origin, self.buffer.items[i + 3].origin };
            if (std.simd.firstIndexOfValue(load, vertex)) |ind| {
                i = i + ind + 1; // skip found HalfEdge next time
                return i - 1;
            }
        }
        while (i < bufferSize) : (i += 1) { // do not-full loads manually
            if (self.buffer.items[i].origin == vertex) {
                i += 1;
                return i - 1;
            }
        }
        return null;
    }

    /// Adds extra penalty (quadric-error from boundary plane times `penalty`) to moving vertices from a boundary
    fn addBoundaryErrors(self: *HalfEdges, penalty: f32) !void {
        const halfEdges = self.HE;
        const normals = self.faceNormals;
        const vertices = self.vertices;
        const errorMatrices: []ErrorMatrix = if (self.quadricError != null) self.quadricError.? else return HalfEdgeError.NoQuadricErrors;


        for(halfEdges) | he | {
            if(he.i_face == null) { // If edge is on a boundary -> alter vertices to have penalty away from boundary
                // Get edge information
                const boundaryHE = halfEdges[he.twin];
                const F = boundaryHE.i_face.?;

                const i_1 = boundaryHE.origin;
                const i_2 = halfEdges[boundaryHE.next].origin;
                
                const V_1 = vertices[i_1*3..][0..3];
                const V_2 = vertices[i_2*3..][0..3];

                const V_edge:[3]f32 = .{V_2[0]-V_1[0], V_2[1]-V_1[1], V_2[2]-V_1[2]};
                const V_normal = normals[F..][0..3].*;

                const V_norm_boundary = math.vec3Cross(V_edge, V_normal);
                const a = V_norm_boundary[0];
                const b = V_norm_boundary[1];
                const c = V_norm_boundary[2];
                const d = a*V_1[0] + b*V_1[1] + c*V_1[2];
                
                const errBoundMat: ErrorMatrix = .{ a * a*penalty,  a * b*penalty,  a * c*penalty,  a * d*penalty,
                                                                    b * b*penalty,  b * c*penalty,  b * d*penalty,
                                                                                    c * c*penalty,  c * d*penalty, 
                                                                                                    d * d*penalty};
                
                for([2]u32{i_1,i_2}) | i | {
                    const errMat = &errorMatrices[i];
                    errMat[0] += errBoundMat[0];
                    errMat[1] += errBoundMat[1];
                    errMat[2] += errBoundMat[2];
                    errMat[3] += errBoundMat[3];
                    errMat[4] += errBoundMat[4];
                    errMat[5] += errBoundMat[5];
                    errMat[6] += errBoundMat[6];
                    errMat[7] += errBoundMat[7];
                    errMat[8] += errBoundMat[8];
                    errMat[9] += errBoundMat[9];
                }
            }
        }
    }

    /// Returns error matrices based on indices, vertices, and normals. Sorting mirrors `self.vertices`
    fn addErrorMatrices(self: *HalfEdges, boundaryPenalty: f32) !void {
        // ===== Retreive mesh constituent =====
        const allocator = self.allocator;
        const vertices = self.vertices;
        const indices = self.indices;
        const normals = self.faceNormals;

        // ===== Create errorMatrices =====
        const triangleCount = @divExact(normals.len, 3);
        const vertexCount = vertices.len;

        const errMatrices = try allocator.alloc(ErrorMatrix, vertexCount);
        for (errMatrices) |*m| m.* = .{0} ** HalfMatLen;

        // ===== Determine errMatrices per face =====
        var i: usize = 0;
        while (i < triangleCount) : (i += 1) {
            // const printCond = indices[i*3+0] == 0 or indices[i*3+1] == 0 or indices[i*3+2] == 0; 
            
            const i_a = indices[i * 3];
            const a = normals[i * 3];
            const b = normals[i * 3 + 1];
            const c = normals[i * 3 + 2];
            const d = -(vertices[i_a * 3] * a + vertices[i_a * 3 + 1] * b + vertices[i_a * 3 + 2] * c);
            const errFaceMat: ErrorMatrix = .{ a * a, a * b, a * c, a * d, b * b, b * c, b * d, c * c, c * d, d * d };
            for (0..3) |j| {
                const errMat = &errMatrices[indices[i * 3 + j]];
                errMat[0] += errFaceMat[0];
                errMat[1] += errFaceMat[1];
                errMat[2] += errFaceMat[2];
                errMat[3] += errFaceMat[3];
                errMat[4] += errFaceMat[4];
                errMat[5] += errFaceMat[5];
                errMat[6] += errFaceMat[6];
                errMat[7] += errFaceMat[7];
                errMat[8] += errFaceMat[8];
                errMat[9] += errFaceMat[9];
            }
        }
        
        self.quadricError = errMatrices;
        if (boundaryPenalty != 0) try self.addBoundaryErrors(boundaryPenalty);
    }

    fn getFaceNormals(allocator: Allocator, vertices: []f32, indices: []u32) ![]f32 {
        const triangleCount = @divExact(indices.len, 3);
        const faceNormals = try allocator.alloc(f32, triangleCount * 3);

        var i: usize = 0;
        while (i < triangleCount) : (i += 1) {
            const i_a: u32 = indices[i * 3];
            const i_b: u32 = indices[i * 3 + 1];
            const i_c: u32 = indices[i * 3 + 2];

            // const debugCond = i_a == 0 or i_b == 0 or i_c == 0;

            // if(debugCond) std.debug.print("V1: ({d}, {d}, {d})\n", .{vertices[i_a * 3], vertices[i_a * 3+1], vertices[i_a * 3+2]});
            // if(debugCond) std.debug.print("V2: ({d}, {d}, {d})\n", .{vertices[i_b * 3], vertices[i_b * 3+1], vertices[i_b * 3+2]});
            // if(debugCond) std.debug.print("V3: ({d}, {d}, {d})\n", .{vertices[i_c * 3], vertices[i_c * 3+1], vertices[i_c * 3+2]});

            const V1: avec3 = vertices[i_a * 3 ..][0..3].*;
            const V2: avec3 = vertices[i_b * 3 ..][0..3].*;
            const V3: avec3 = vertices[i_c * 3 ..][0..3].*;

            const edge1 = V2 - V1;
            const edge2 = V3 - V1;
            const tmp_0 = @shuffle(f32, edge1, edge1, avec3{ 1, 2, 0 });
            const tmp_1 = @shuffle(f32, edge2, edge2, avec3{ 2, 0, 1 });
            const tmp_2 = tmp_0 * edge2;
            const tmp_3 = @shuffle(f32, tmp_2, tmp_2, avec3{ 1, 2, 0 });
            const tmp_4 = tmp_0 * tmp_1;
            const cross = tmp_4 - tmp_3; // Edge 1 x edge 2 

            @memcpy(faceNormals[i * 3 ..][0..3], @as([3]f32, math.vec3returnNormalize(cross))[0..]);
            // if(debugCond) std.debug.print("normal: ({d}, {d}, {d})\n", .{faceNormals[i*3], faceNormals[i*3+1], faceNormals[i*3+2]});
        }
        return faceNormals;
    }

    pub fn printEdgeHeader() void {
        std.debug.print("Edge       | Origin     | Twin       | Next       | Prev       | i_face     |\n", .{});
    }

    pub fn printEdgeWithOrigin(self: HalfEdges, origin: u32) void {
        for(self.HE, 0..) | he, edge | {
            if(he.origin == origin) {
                self.printEdge(edge);
                self.printEdge(he.twin);
            }
        }
    }

    pub fn printEdge(self: HalfEdges, edge_ind: usize) void {
        const edge = self.HE[edge_ind];
        const origin = edge.origin;
        const twin = edge.twin;
        const face = edge.i_face;
        const next_ = edge.next;
        const prev = edge.prev;
        std.debug.print("{d:<10} | {d:<10} | {d:<10} | {d:<10} | {d:<10} | {?:<10} |\n", .{edge_ind, origin, twin, next_, prev, face});
    }

    fn printFace(V1: [3]f32, V2: [3]f32, V3: [3]f32) void {
        std.debug.print("({d:<9.5}, {d:<9.5}, {d:<9.5}), ({d:<9.5}, {d:<9.5}, {d:<9.5}), ({d:<9.5}, {d:<9.5}, {d:<9.5})\n", .{V1[0], V1[1], V1[2], V2[0], V2[1], V2[2], V3[0], V3[1], V3[2]});
    }

    fn printVector(v: [3]f32) void {
        std.debug.print("({d:<9.5}, {d:<9.5}, {d:<9.5})\n", .{v[0], v[1], v[2]});
    }

    fn errInfoCompare(_: void, e1: EdgeErrInfo, e2: EdgeErrInfo) bool {
        return e1.err < e2.err;
    }
};

const LinkedErrorsErrors = error{ ItemNotFound,
                                        EndOfChain,
                                        StartOfChain,
                                        EmptyChain,
                                        InvalidFlagRemoval,
                                        AllItemsExceedError,};

pub const LinkedErrors = struct {
    allocator: Allocator,

    errorCutOff: f32,
    edgeErrors: []EdgeErrInfo,
    flagged: []?u16,
    linkedList: []LinkedItem,
    linkStart: u32,
    linkEnd: u32,
    valueFlags: std.ArrayList(FlagItem),

    /// Returns linked list of errors which may be used to perform certain operations like insertions, alterations, and re-evaluating entries.
    /// 
    /// Linked-items have an index corresponding to edgeErrors. Linked-items will link-up to be ordered according to ascending collapse-errors
    pub fn fromEdgeErrors(allocator: Allocator, edgeErrors: []EdgeErrInfo, errorCutOff: f32) !LinkedErrors {
        // ===== Create HalfEdges with indices for linkedList ===== 
        const itemCount: u32 = @intCast(edgeErrors.len);
        
        // ===== Create linked list =====
        const linkedList = try allocator.alloc(LinkedItem, itemCount);

        // Set values
        var i:u32 = 0;
        while(i<itemCount):(i+=1){
            linkedList[i].value = edgeErrors[i].err;
        }

        // connect 'linkedList' to be sorted & retreive sorted indices of edgeErrors 'surrogateLinks'
        const surrogateLinks = try linkUpToAscendingValues(allocator, linkedList);
        defer allocator.free(surrogateLinks);
        const linkStart = surrogateLinks[0].originalIndex;
        const linkEnd = surrogateLinks[itemCount-1].originalIndex; // Last item in linked list

        // ===== Create value-flags (linkedList-order) =====
        const validEdgeCount = std.sort.lowerBound(SurrogateLink, surrogateLinks, errorCutOff, cutOffCompare); // return index of first edge above cutOff value
        const flagCount: usize = if(validEdgeCount > 0) @max(@divTrunc(validEdgeCount, @as(usize, @intFromFloat(@round(@sqrt(@as(f32, @floatFromInt(validEdgeCount))))))), 1) else 1; // return sqrt(n) flags | enforce O(sqrt(n))?

        var valueFlags = try std.ArrayList(FlagItem).initCapacity(allocator, flagCount);
        
        // ----- keep track of which LinkedItem is flagged -----
        const flagged = try allocator.alloc(?u16, itemCount); // flagged[edge] = index in self.valueFlags
        for (0..itemCount) |j| flagged[j] = null;

        // ----- populate value flags -----
        const flagSpacing:u16 = @intCast(@divFloor(validEdgeCount, flagCount));
        var j: u16 = 0; // flag-index
        while(j<flagCount):(j+=1) {
            const index = surrogateLinks[j*flagSpacing].originalIndex; // index of flag-position in linkedList

            flagged[index] = j; // store flag-index on index of flagged edge
            valueFlags.appendAssumeCapacity(.{ // create and store flagItem
                .index = index,
                .err = linkedList[index].value,
                });
        }

        // ===== Construct result and return =====
        return .{
            .allocator = allocator,
            .edgeErrors = edgeErrors,
            .flagged = flagged,
            .errorCutOff = errorCutOff,
            .linkedList = linkedList,
            .linkStart = linkStart,
            .linkEnd = linkEnd,
            .valueFlags = valueFlags,
        };
    }

    /// change `linkedList` references (`i_prev` and `i_next`) such that `i_next` always refers to an item with a higher value and vice versa.
    /// 
    /// start and end of chain link to invalid index `linkedList.len`
    /// 
    /// returns surrogateLinks which is a sorted list of error values with their respective indices attached. 
    pub fn linkUpToAscendingValues(allocator: Allocator, linkedList: []LinkedItem) ![]SurrogateLink {

        // ===== Make surrogate linked-Items =====
        const itemCount: u32 = @intCast(linkedList.len);
        const surrogates = try allocator.alloc(SurrogateLink, @intCast(itemCount));
        
        var i:u32 = 0;
        while(i<itemCount):(i+=1){
            surrogates[i] = SurrogateLink{
                .originalIndex = i,
                .value = linkedList[i].value,
            };
        }

        // ===== Sort surrogates =====
        std.mem.sortUnstable(SurrogateLink, surrogates, {}, surrogateCompare);

        // ===== re-link linkedList =====
        linkedList[surrogates[0].originalIndex].i_prev = itemCount;
        linkedList[surrogates[0].originalIndex].i_next = surrogates[1].originalIndex;
        linkedList[surrogates[itemCount-1].originalIndex].i_next = itemCount;
        linkedList[surrogates[itemCount-1].originalIndex].i_prev = surrogates[itemCount-2].originalIndex;

        i = 1;
        while(i<itemCount-1):(i+=1) {
            const i_prev = surrogates[i-1].originalIndex;
            const i_next = surrogates[i+1].originalIndex;
            const item = &linkedList[surrogates[i].originalIndex];
            item.i_next = i_next;
            item.i_prev = i_prev; 
        }

        return surrogates;
    }

    pub fn deinit(self: LinkedErrors) void {
        const allocator = self.allocator;

        self.valueFlags.deinit();

        allocator.free(self.flagged);
        allocator.free(self.linkedList);
    }

    /// Set end to previous item in linkedList
    pub fn moveEndDown(self: *LinkedErrors) !void {
        const LLLen = self.linkedList.len;
        const nextEnd = self.linkedList[self.linkEnd].i_prev;
        if (nextEnd == LLLen) return LinkedErrorsErrors.EmptyChain;
        // std.debug.print("Moving end to edge {}\n", .{nextEnd});
        self.linkEnd = nextEnd;
    }

    /// Set start to next item in linkedList
    pub fn moveStartUp(self: *LinkedErrors) !void {
        const LLLen = self.linkedList.len;
        const nextStart = self.linkedList[self.linkStart].i_next;
        if (nextStart == LLLen) return LinkedErrorsErrors.EndOfChain;
        // std.debug.print("Moving start to edge {}\n", .{nextStart});
        self.linkStart = nextStart;
    }

    /// Set start to previous item in linkedList
    pub fn moveStartDown(self: *LinkedErrors) !void {
        const LLLen = self.linkedList.len;
        
        const nextStart = self.linkedList[self.linkStart].i_prev;
        if (nextStart == LLLen) return LinkedErrorsErrors.StartOfChain;

        // std.debug.print("Moving start to edge {}\n", .{nextStart});
        self.linkStart = nextStart;
    }

    /// Resets start to beginning of chain
    pub fn resetStart(self: *LinkedErrors) void {
        const LL = self.linkedList;
        const LLLen: u32 = @intCast(LL.len);

        var i: u32 = self.linkStart;
        while(LL[i].i_prev != LLLen){
            i = LL[i].i_prev;
        }

        self.linkStart = i;
    }

    /// Alters `self.linkedList` to keep links in an ascending order.
    /// 
    /// Re-orders linked-list after evaluating new collapse-errors `alteredErrors`
    /// 
    /// updates `self.edgeErrors`
    /// 
    /// Returns EndOfChain error if start has reached last item in chain
    /// Returns EmptyChain error if chain has no more valid members
    pub fn reevaluateEntries(self: *LinkedErrors, alteredErrors: []AlteredEdgeErrorInfo) !void {
        // const halfEdges = self.edgeErrors;
        const alteredCount = alteredErrors.len; 

        // ===== Sort altered Edges =====
        std.mem.sortUnstable(AlteredEdgeErrorInfo, alteredErrors, {}, edgeChangeCompare);

        // ===== Set linkItem and edgeError values =====
        const linkedList = self.linkedList;
        const edgeErrors = self.edgeErrors;
        
        var i:u32 = 0;
        while(i<alteredCount):(i+=1){
            const edgeIndex = alteredErrors[i].index;
            edgeErrors[edgeIndex] = alteredErrors[i].edgeErrorInfo;
            linkedList[edgeIndex].value = alteredErrors[i].edgeErrorInfo.err;
        }

        // ===== Remove altered values from linkedList =====
        // NOTE: Needs linkedList.values to be set for flag moving
        var EmptyChain = false;
        var EndOfChain = false;
        var AllItemsExceedError = false;
        
        i = 0;
        std.debug.print("edge[781] exists before removal: {}\n", .{self.inChain(781)});
        while(i<alteredCount):(i+=1) {
            if(alteredErrors[i].index == 774) std.debug.print("Removing edge[{}] for re-sorting\n", .{alteredErrors[i].index});
            // std.debug.print("Removing edge: {d:<10}\n", .{alteredErrors[i].index});
            self.removeItemCareful(alteredErrors[i].index) catch | err | switch (err) {
                LinkedErrorsErrors.EndOfChain => EndOfChain = true,
                LinkedErrorsErrors.EmptyChain => EmptyChain = true,
                LinkedErrorsErrors.AllItemsExceedError => AllItemsExceedError = true,
                else => return err,
            };
        }
        std.debug.print("edge[781] exists after removal: {}\n", .{self.inChain(781)});

        // ===== Insert altered data =====
        const flags = self.valueFlags.items;
        const cutOffError = self.errorCutOff;
        // const LLLen: u32 = @intCast(linkedList.len);

        i = 0;
        var i_flag:usize = 0;
        var i_insert: u32 = 0;
        while(i<alteredCount):(i+=1) {
            std.debug.print("edge[781] exists at start of loop({}): {}\n", .{i, self.inChain(781)});
            if(i==0) std.debug.print("inserting item[{}]\n", .{alteredErrors[i].index});
            const alteredErr = alteredErrors[i].edgeErrorInfo.err; // new edge error
            const alteredInd = alteredErrors[i].index; // halfEdge index
            
            // ----- check if chain exists -----
            if(EmptyChain) {
                std.debug.print("Seeding chain\n", .{});
                try self.seedChain(alteredInd);
                EndOfChain = false;
                EmptyChain = false;
                continue;
            }

            // if(alteredInd == 774) std.debug.print("Inserting Edge[774]...\n", .{});
            // ----- check if item has valid error -----
            if(alteredErr > cutOffError){ // if halfEdge error is too large -> attach to end of chain
                if(alteredInd == 774 and i == 0) {
                    self.printChain(100);
                    std.debug.print("errorTooLarge\n", .{});
                    std.debug.print("self.linkEnd: {}\nself.linkStart: {}\nfirstFlagInd:{}\n", .{self.linkEnd, self.linkStart, self.valueFlags.items[0].index});
                    std.debug.print("edge[781] exists before insertion: {}\n", .{self.inChain(781)});
                }

                if(EndOfChain) {
                    if(self.linkEnd == self.linkStart) {
                        self.linkStart = alteredInd; // new item is attached to end -> move start their
                        EndOfChain = false; // insert causes self.linkStart to not be last item anymore
                    }
                }

                self.insertItem(alteredInd, self.linkEnd);
                if(alteredInd == 774 and i == 0) std.debug.print("edge[781] exists after insertion: {}\n", .{self.inChain(781)});


                continue;
            }

            // ----- check if item should be inserted before start -----
            if(alteredErr<self.valueFlags.items[0].err){ // Only applies to first altered item really
                if(alteredInd == 774 and i == 0) std.debug.print("smallestError\n", .{});
                
                try self.insertItemBefore(alteredInd, self.valueFlags.items[0].index);
                AllItemsExceedError = false;
                continue;
            }

            // ----- do rough position scan using flags -----
            const flag_ind_found: usize = std.sort.upperBound(FlagItem, flags[i_flag..], alteredErr, flagErrCompare) - 1; // Returns flag index with invalid error value | search [(flag_returned-1).index..flag_returned.index]
            i_flag += flag_ind_found; //if(flag_ind_found == flags.len-i_flag) flag_ind_found-1 else | There is no flag on cutOffError -> so if in last section returns flags.len 

            if (i_flag == flags.len) { // if flag cannot be found for error value -> value should be in last flag region: err is inside [flag_last.err..err_cutoff]
                i_flag -= 1;
            }

            // ----- search exact insertion position from flag.index -----
            i_insert = if(flag_ind_found != 0) 
                try self.findLLSpot(alteredErr, flags[i_flag].index) 
            else 
                try self.findLLSpot(alteredErr, i_insert); // if in same flag section -> Use previous found index to start search

            self.insertItem(alteredInd, i_insert);

            // ===== Handle potential errors =====
            if(EndOfChain and i_insert == self.linkEnd) { // If linkStart reached end of chain, but chain expands -> move to expanded item
                self.linkStart = alteredInd;
                EndOfChain = false;
            }
        }

        if(EmptyChain) return LinkedErrorsErrors.EmptyChain;
        if(EndOfChain) return LinkedErrorsErrors.EndOfChain;
        if(AllItemsExceedError) {
            self.printChainItems(10);
            if(self.inChain(781)) std.debug.print("edge[781] is in chain with error: {d}\n", .{self.edgeErrors[781].err}) else std.debug.print("edge[781] not in the chain", .{});
            return LinkedErrorsErrors.AllItemsExceedError;
        }
    }

    /// Return index of edgeErrors with lowest collapsing-error.
    /// 
    /// Return null if lowest error exceeds cutOff error.
    pub fn getEdgeIndexWithLowestError(self: LinkedErrors) ?u32 {
        const result = if (self.linkedList[self.linkStart].value < self.errorCutOff) self.linkStart else null;
        return result;
    }

    // /// Return value of
    // pub fn getLowestError(self: LinkedErrors) f32 {
    //     return self.linkedList[self.linkStart].value;
    // }

    /// Insert LinkedItem after index `i_insert`
    /// 
    /// moves `self.EndOfChain` if insert is last item
    pub fn insertItem(self: *LinkedErrors, i_linkedItem: u32, i_insert: u32) void {
        const LL = self.linkedList;
        const LLLen = LL.len;
        const nextInd = LL[i_insert].i_next;
        const currItem = &LL[i_linkedItem];

        // ===== insert item in chain =====
        if (nextInd < LLLen) LL[nextInd].i_prev = i_linkedItem; // if next item exists
        currItem.i_next = nextInd;
        LL[i_insert].i_next = i_linkedItem;
        currItem.i_prev = i_insert;

        // ===== Change self.linkEnd if needed =====
        if(i_insert == self.linkEnd){
            std.debug.print("Moved self.linkEnd\n", .{});
            self.linkEnd = i_linkedItem;
        }
    }
    
    /// Insert LinkedItem before index `i_insert`
    /// 
    /// moves first flag if insert is first item in chain
    /// 
    /// moves `self.linkStart` to `i_linkedItem` if inserted before `self.linkStart`. 
    pub fn insertItemBefore(self: *LinkedErrors, i_linkedItem: u32, i_insert: u32) !void {
        const LL = self.linkedList;
        const LLLen = LL.len;
        const prevInd = LL[i_insert].i_prev;
        const currItem = &LL[i_linkedItem];

        // ===== insert item in chain =====
        if (prevInd < LLLen) LL[prevInd].i_next = i_linkedItem; // if previous item exists
        currItem.i_prev = prevInd;
        LL[i_insert].i_prev = i_linkedItem;
        currItem.i_next = i_insert;

        // ===== Change self.linkEnd if needed =====
        const i_chainStart = self.valueFlags.items[0].index;
        const i_start = self.linkStart;
        
        if(i_insert == i_chainStart){
            try self.moveFlagDown(0);
        }
        if(i_insert == i_start){
            self.linkStart = i_linkedItem;
        }
    }

    /// Make new chain, and attach `self.linkStart` & `self.linkEnd` to it.
    /// 
    /// Chain will only have a single flag
    pub fn seedChain(self: *LinkedErrors, i_linkedItem: u32) !void {
        // ===== Attach start and end =====
        self.linkStart = i_linkedItem;
        self.linkEnd = i_linkedItem;
        
        // ===== Remove old flagging system =====
        for(self.valueFlags.items) | flagItem | {
            self.flagged[flagItem.index] = null;
        }
        self.valueFlags.clearRetainingCapacity();

        // ===== Create value-flag =====
        try self.valueFlags.append(.{ .err = self.linkedList[i_linkedItem].value, .index = i_linkedItem});
        self.flagged[i_linkedItem] = 0;
    }

    /// Removes edge with `edgeIndex` from self, as well as edges which share the same face.
    /// 
    /// Uses connections as defined in halfEdges.
    /// 
    /// Standard behaviour is careful removal of edges. As well as not propegating the edge-removal if face is null
    /// 
    /// If removal returns error, attempts to finish removals before returning error.
    pub fn removeFaceOfEdge(self: *LinkedErrors, edgeIndex: u32, halfEdges: []HalfEdge) !void {
        // std.debug.print("removing face of {}\n", .{edgeIndex});
        var i:u32 = edgeIndex;
        
        var EndOfChain: bool = false;
        var EmptyChain: bool = false;
        var AllItemsExceedError: bool = false;

        // ----- do first removal manually -----
        // const f1 = halfEdges[edgeIndex].i_face;

        // if(f1 == 2256 or f1 == 2259 or f1 == 2262 or f1 == 2265 or f1 == 2271 or f1 == 2268 or f1 == 2274 or f1 == 2283 or f1 == 2280){
        //     std.debug.print("removing edge({})-face {}\n", .{edgeIndex, f1.?});
        //     std.debug.print("edge[{}]: {any}\n", .{2268, halfEdges[2268]});
        //     std.debug.print("edge[{}]: {any}\n", .{2271, halfEdges[2271]});
        // }
        
        // if(i == 3894 or i == 3889 or i == 3888 or i == 3890 or i == 3891 or i == 3893){
        //     std.debug.print("removing: {}\n", .{i});
        //     if (i == 3890) return error.Unexpected;
        // }
        
        self.removeItemCareful(i) catch | err | switch (err) {
            LinkedErrorsErrors.EndOfChain => EndOfChain = true,
            LinkedErrorsErrors.EmptyChain => EmptyChain = true,
            LinkedErrorsErrors.AllItemsExceedError => AllItemsExceedError = true,
            else => return err,
        };

        if(halfEdges[edgeIndex].i_face != null) { // if original edge is adjacent to defined face
            i = halfEdges[i].next;
            while(i != edgeIndex):(i = halfEdges[i].next) {        
                // if(i == 3894 or i == 3889 or i == 3888 or i == 3890 or i == 3891 or i == 3893){
                //     std.debug.print("removing: {}\n", .{i});
                //     if (i == 3890) return error.Unexpected;
                // }
                // std.debug.print("removing edge {}\n", .{i});
                self.removeItemCareful(i) catch | err | switch (err) {
                    LinkedErrorsErrors.EndOfChain => EndOfChain = true,
                    LinkedErrorsErrors.EmptyChain => EmptyChain = true,
                    LinkedErrorsErrors.AllItemsExceedError => AllItemsExceedError = true,
                    else => return err,
                };
            }
        }

        if (AllItemsExceedError) return LinkedErrorsErrors.AllItemsExceedError;
        if (EndOfChain) return LinkedErrorsErrors.EndOfChain;
        if (EmptyChain) return LinkedErrorsErrors.EmptyChain;
    }

    /// Same as `self.removeItem()` but moves `self.linkStart` forward if it is currently on the removed edge.
    /// 
    /// Moving has 4 outcomes:
    /// - No error, moved start as expected
    /// - EndOfChain, start could not be moved up, item was deleted first -> self.chainStart is invalid
    /// - EmptyChain, end could not be moved down, item was deleted first -> self.chainEnd is invalid
    /// - Misc error, unexpected
    pub fn removeItemCareful(self: *LinkedErrors, edgeIndex: u32) !void {
        if(self.linkStart == edgeIndex) self.moveStartUp() catch | err | switch (err) { // if linkStart is in danger of being displaced of the chain -> move up-chain
            LinkedErrorsErrors.EndOfChain => {
                // std.debug.print("Start did not move up\n", .{});
                try self.removeItem(edgeIndex);
                return err;
            },
            else => return err,
        }; 
        if(self.linkEnd == edgeIndex) self.moveEndDown() catch | err | switch (err) {  // if linkEnd is in danger of being displaced of the chain -> move end down
            LinkedErrorsErrors.EmptyChain => {
                // std.debug.print("End did not move down\n", .{});
                try self.removeItem(edgeIndex);
                return err;
            },
            else => return err,
        };
        try self.removeItem(edgeIndex);
    }


    /// Remove edge `edgeIndex` (index in `self.halfEdges`) from `self.linkedList`.
    /// 
    /// Moves flag from `self.valueFlags` with 1 if it refers to to-be-removed item. 
    pub fn removeItem(self: *LinkedErrors, edgeIndex: u32) !void {
        const LL = self.linkedList;
        const flagged = self.flagged;

        // ===== Alter flag if necesary =====
        if(flagged[edgeIndex]) | _ | {
            if(edgeIndex == 774) std.debug.print("moving flag[{?}]\n", .{flagged[edgeIndex]});
            self.printChainItems(10);
            try self.moveFlag(edgeIndex); // ERRORS HERE -> DOES NOT MOVE FLAG -> ITEM DOES NOT GET REMOVED
            std.debug.print("new flag[0].index: {}\n", .{self.valueFlags.items[0].index});
            self.printChainItems(10);
        }

        const item = &LL[edgeIndex];
        
        if (item.i_prev<LL.len) LL[item.i_prev].i_next = item.i_next; // if valid item index -> link index to point around itself
        if (item.i_next<LL.len) LL[item.i_next].i_prev = item.i_prev;
    }

    /// Find index in linkedList for which all next items have a larger error. 
    /// 
    /// If linkedList does not contain a larger index return last item
    /// 
    /// If index is at very start of chain, return `self.linkedList.len`
    fn findLLSpot(self: LinkedErrors, err: f32, startIndex: usize) !u32 {
        const linkedList = self.linkedList;
        const itemCount = linkedList.len;

        var i:usize = startIndex;
        // var debug:usize = 0;
        while(true){
            // if(debug>500) return error.Unexpected else debug+=1;
            // std.debug.print("{}|", .{i});
            const linkedItem = linkedList[i];
            if(linkedItem.i_next == itemCount) {
                // std.debug.print("^", .{});
                return @intCast(i); // If i_next is invalid -> end of links -> use last valid index
            }
            if(linkedItem.value>err) {
                // std.debug.print("<-", .{});
                return linkedItem.i_prev; // return index of spot it should be inserted
            }
            
            i = linkedItem.i_next; // If error is still smaller -> Check next index
        }
    }

    /// Move flag with index `flagInd` inside `self.valueFlags`, up or down by 1.
    /// 
    /// Attempts to keep item count in neighbouring regions equal
    /// 
    /// If no plausible flag spot is possible, replace next flag
    /// 
    /// Removes flag if total items in own and previous region exceed flagCount (enforce flagCount = itemCount in region -> sqrt(n) search)
    /// 
    /// If flag moves outside of linkedList assume error is too large and remove flag 
    fn moveFlag(self: *LinkedErrors, edgeInd: u32) !void {
        // std.debug.print("Moving flag[{}] on edge ({})...\n", .{self.flagged[edgeInd].?, edgeInd});
        // ===== Store constants =====
        const flagged = self.flagged;
        const flags = self.valueFlags.items;
        const flagCount: u32 = @intCast(flags.len);

        // ----- check flags existence -----
        if (flagged[edgeInd] == null) return; // no flag -> return
        
        // ===== remove flag from edgeInd =====

        // ===== Determine where flag should move =====
        // ----- determine flag and neighbour flags -----
        const i_flag = flagged[edgeInd].?;
        const currFlag = &flags[i_flag];
        const prevFlag = if(i_flag == 0)                null else &flags[i_flag-1];
        const nextFlag = if(i_flag + 1 >= flagCount)    null else &flags[i_flag+1];


        // ----- Go over edge case -----
        if (prevFlag == null) {
            try self.moveFlagUp(i_flag); // If first flag -> Can only move up
            return;
        }
        
        // ----- determine size of prior/curr flag region -----
        const LL = self.linkedList;
        
        var prevSize:u16 = 0;

        var i:u32 = prevFlag.?.index;
        while(i!=currFlag.index){
            prevSize +=1;
            i = LL[i].i_next;
        }

        var currSize:u16 = 0;
        i = currFlag.index;
        if(nextFlag == null){ // go till error
            const cutOff = self.errorCutOff;
            if(LL[self.linkEnd].value < cutOff) {
                while(i != self.linkEnd):(i = LL[i].i_next){
                    currSize+=1;
                }
            }else{
                while(LL[i].value < cutOff):(i=LL[i].i_next){
                    currSize+=1;
                }
            }

        }else{ // go till next flag
            while(i != nextFlag.?.index):(i = LL[i].i_next){
                currSize+=1;
            }
        }

        // ----- check if flag should be removed -----
        if(prevSize+currSize < flagCount) {
            // std.debug.print("flag0\n", .{});
            try self.removeFlag(i_flag);
            return;
        }

        if(prevSize>currSize){
            // std.debug.print("flag1\n", .{});
            try self.moveFlagDown(i_flag);
        } else{
            // std.debug.print("flag2\n", .{});
            try self.moveFlagUp(i_flag);
        }

    }

    /// Removes flag
    fn removeFlag(self: *LinkedErrors, i_flag: u16) !void {
        if(i_flag == 0) {
            self.printChain(2000);
            return LinkedErrorsErrors.InvalidFlagRemoval;
        }

        // std.debug.print("Removing flag[{}] on edge {d:<10}\n", .{i_flag, self.valueFlags.items[i_flag].index});

        const flagged = self.flagged;
        const flags = self.valueFlags.items;
        const flagCount = flags.len;

        const flaggedEdge = flags[i_flag].index;
        flagged[flaggedEdge] = null;
        // std.debug.print("flagged[{}]: {?}\n", .{flaggedEdge, flagged[flaggedEdge]});

        var i:u16 = i_flag+1; // change flagged pointers of all subsequent flags
        while(i<flagCount):(i+=1){
            flagged[flags[i].index] = i-1; // move flag pointers in flagged to prior flag
        }
        _ = self.valueFlags.orderedRemove(i_flag); // remove i_flag
        
    }

    /// Move flag up by 1. May invalidate pointers to self.valueFlags
    /// 
    /// Special cases:
    /// - Next index already has a flag                 -> replace flag
    /// - Flag is on last item of `self.linkedList`     -> remove flag 
    /// - Flag moves to an item with too large an error -> remove flag
    fn moveFlagUp(self: *LinkedErrors, i_flag: u16) !void {
        const flagged = self.flagged;
        const flags = self.valueFlags.items;
        const flagCount = flags.len;
        const LL = self.linkedList;

        const flaggedEdge = flags[i_flag].index;

        // ===== Remove current references =====
        flagged[flaggedEdge] = null;

        // ===== Re-construct flag =====
        const flag = &flags[i_flag];
        const newFlagIndex = LL[flaggedEdge].i_next; // index into Linked List
        // std.debug.print("oldFlagPos: {}\nnewFlagPos: {}\n", .{flaggedEdge, newFlagIndex});

        // ----- verify that flag is in correct region -----
        if (LL[newFlagIndex].value >= self.errorCutOff) { 
            if(i_flag != 0){
                try self.removeFlag(i_flag);
                return;
            } else {
                // if(self.inChain(781)) {
                //     std.debug.print("Edge 781 is still in chain\n", .{});
                //     std.debug.print("Error: {} = {} / {}\n", .{self.edgeErrors[781].err, LL[781].value, self.errorCutOff});
                //     std.debug.print("\nflags[0].prevInd: {}/{}\n", .{LL[flags[0].index].i_prev, LL.len});
                //     // self.printChain(@intCast(self.valueFlags.items.len));
                //     self.printChainItems(10);
                //  } else std.debug.print("Edge 781 is not in chain\n", .{});
                return LinkedErrorsErrors.AllItemsExceedError;
            }
        }

        if (newFlagIndex != LL.len) { // if next item exists
            // std.debug.print("valid new index found: {}\n", .{newFlagIndex});
            flagged[newFlagIndex] = i_flag; // link linkedItem index to flag index of flagged item
            
            // if (newFlagIndex == 37205){
            //     std.debug.print("MOVING FLAG [33?] TO NEW POSITION\n", .{});
            //     std.debug.print("set flag[{}] to ({d:10} | {d:10})\n", .{i_flag, newFlagIndex, self.linkedList[newFlagIndex].value});
            //     std.debug.print("item[{}]:\n", .{newFlagIndex});
            //     std.debug.print("{any}\n", .{self.linkedList[newFlagIndex]});
            //     std.debug.print("nextItem.prev: {}\n", .{self.linkedList[self.linkedList[newFlagIndex].i_next].i_prev});
            //     std.debug.print("prevItem.next: {}\n", .{self.linkedList[self.linkedList[newFlagIndex].i_prev].i_next});
            //     self.printChain(33);
            // }
            flag.index = newFlagIndex; // Set flag index to new LL-index
            flag.err = self.linkedList[newFlagIndex].value; // set flag value

            // ----- handle flag overlapping -----
            const nextFlagInd = if(i_flag != flagCount-1) flags[i_flag+1].index else return; // index in LL of next flag | if last flag item -> No overlapping
            if(newFlagIndex == nextFlagInd) { // if flag overlaps with next flag index
                // std.debug.print("Flags [{}] & [{}] overlap -> Remove flag[{}]\n", .{i_flag, i_flag + 1, i_flag + 1});
                try self.removeFlag(i_flag+1); // remove next flag
                flagged[newFlagIndex] = i_flag; // removeFlag will remove flagged[prev_flag] which is now overlapping -> rewrite it

            }
        } else { // If flag points to unreachable chain item -> Remove flag
            _ = self.valueFlags.orderedRemove(i_flag);
        }
    }

    /// Move flag down by 1. May invalidate pointers to self.valueFlags
    /// 
    /// Special cases:
    /// - Previous index already has a flag             -> remove flag
    /// - Flag is on first item of `self.linkedList`    -> return error 
    fn moveFlagDown(self: *LinkedErrors, i_flag: u16) !void {
        const flagged = self.flagged;
        const flags = self.valueFlags.items;
        const LL = self.linkedList;

        const flaggedEdge = flags[i_flag].index;

        // if (flaggedEdge == 2737){
        //     std.debug.print("moving flag[{}] down from edge {d:<10}\n", .{i_flag, flaggedEdge});
            
        //     for ([_]u32{2016, 2017, 2018, 2020, 2022, 2032, 2051, 2064, 2065, 2066, 2068, 2070, 2082, 2111, 2112, 2113, 2114, 2117, 2124, 2128, 2138, 2142, 2149, 2157, 2160, 2161, 2162, 2164, 2172, 2181, 2191, 2208, 2209, 2210, 2212, 2214, 2227, 2256, 2257, 2258, 2259, 2267, 61342, 2285, 61338, 2304, 2305, 2306, 2307, 2310, 2317, 2319, 2320, 2321, 2330, 2334, 2335, 2340, 2349, 2352, 2353, 2354, 2357, 2364, 2367, 2382, 2394, 2400, 2401, 2402, 2405, 2415, 2426, 2430, 2431, 2446, 2448, 2449, 2450, 2453, 2467, 2485, 2493, 2497, 2498, 2499, 2500, 2501, 2503, 2508, 2512, 2522, 2528, 2533, 2541, 2542, 2543, 2544, 2545, 61330, 2550, 2563, 2564, 61325, 2591, 2592, 2593, 2594, 2595, 2603, 2615, 2621, 2640, 2641, 2642, 2644, 2651, 2663, 2688, 2689, 2690, 2693, 2700, 2704, 2714, 2720, 2725, 2733, 2734, 2735, 2736, 2737}) | edgeId | std.debug.print("edge[{d:<7}]: {any}\n", .{edgeId, LL[edgeId]});
        //     std.debug.print("edge[{}]: {any}\n", .{2736, LL[2736]});
            
        //     std.debug.print("edge[{}]: {any}\n", .{flaggedEdge, LL[flaggedEdge]});
        //     self.printChain(2);
        // }

        // ===== Check if flag can be removed =====
        if(i_flag == 0) return LinkedErrorsErrors.InvalidFlagRemoval;
        if(LL[flaggedEdge].i_prev == LL.len) return LinkedErrorsErrors.StartOfChain;

        // ===== Remove current references =====
        flagged[flaggedEdge] = null;

        // ===== Re-construct flag =====
        const flag = &flags[i_flag];
        const newFlagIndex = LL[flaggedEdge].i_prev; // index into Linked List
        
        flagged[newFlagIndex] = i_flag; // link linkedItem index to flag index of flagged item
        
        // if (newFlagIndex == 58292){
        //     std.debug.print("MOVING FLAG [33?] TO NEW POSITION\n", .{});
        //     std.debug.print("set flag[{}] to ({d:10} | {d:10})\n", .{i_flag, newFlagIndex, self.linkedList[newFlagIndex].value});
        //     std.debug.print("item[{}]:\n", .{newFlagIndex});
        //     std.debug.print("{any}\n", .{self.linkedList[newFlagIndex]});
        //     std.debug.print("nextItem.prev: {}\n", .{self.linkedList[self.linkedList[newFlagIndex].i_next].i_prev});
        //     std.debug.print("prevItem.next: {}\n", .{self.linkedList[self.linkedList[newFlagIndex].i_prev].i_next});
        //     self.printChain(33);
        // }

        flag.index = newFlagIndex; // Set flag index to new LL-index
        flag.err = self.linkedList[newFlagIndex].value; // set flag value

        // ----- handle flag overlapping -----
        const prevFlagInd = flags[i_flag-1].index; // index in LL of next flag
        if(newFlagIndex == prevFlagInd) { // if flag overlaps with previous flag index
            try self.removeFlag(i_flag); // remove flag
            flagged[newFlagIndex] = i_flag; // removeFlag clears flagged[prev_flag] which should now be readded
        }
    }

    /// Alter placeHolder mesh to collapsed mesh-state.
    /// 
    /// Mesh should be the parent of the halfEdges to avoid innapropriate memory allocation.
    /// 
    /// Only alters geometry (`mesh.vertices` and `mesh.indices`).
    pub fn updateToPHMesh(self: LinkedErrors, halfEdges: []HalfEdge, mesh: *PlaceHolderMesh) !void {
        // ===== Store constants =====
        const allocator = self.allocator;

        // ===== Store linked list =====
        const LL = self.linkedList;
        const LL_length:u32 = @intCast(LL.len);

        // ===== Store face-adjacent halfEdges =====
        const longEdges: []HalfEdge = try allocator.alloc(HalfEdge, LL.len);

        var i:u32 = self.linkStart;
        var j:u32 = 0; // Count of face-adjacent edges
        while(i < LL_length):(i = LL[i].i_next) {
            if (halfEdges[i].i_face != null) { // go through chain and store edges which have a valid face
                longEdges[j] = halfEdges[i]; 
                j+=1;
            }
        }
        // std.debug.print("j: {}\n", .{j});
        const faceCount = @divExact(j, 3);

        const edges: []HalfEdge = try allocator.realloc(longEdges, j); // trim longedges to valid edges
        defer allocator.free(edges);

        // ===== Find used indices/vertices =====
        const intactVertex: []bool = try allocator.alloc(bool, mesh.vertexCount);
        const intactFace: []bool = try allocator.alloc(bool, mesh.triangleCount);
        defer allocator.free(intactVertex);
        defer allocator.free(intactFace);

        // ----- initialize to false -----
        const minIntactLen = @min(intactFace.len, intactVertex.len);
        i = 0;
        while(i<minIntactLen):(i+=1){
            intactVertex[i] = false;
            intactFace[i] = false;
        }

        switch (intactFace.len < intactVertex.len) {
            true => { // more vertices than faces
                const vertexCount = intactVertex.len;
                while(i<vertexCount):(i+=1){
                    intactVertex[i] = false;
                }
            },
            false => { // more faces than vertices
                const facecount = intactFace.len;
                while(i<facecount):(i+=1){
                    intactFace[i] = false;
                }
            },
        }

        // ----- set intact indices to true -----
        for(edges) | HE | {
            intactVertex[HE.origin] = true; // Vertex is mentioned
            intactFace[@divExact(HE.i_face.?, 3)] = true; // Face is mentioned
        }

        // ===== Realocate indices =====
        const indices = mesh.indices;
        const vertices = mesh.vertices;

        const vertexMoved: []?u32 = try allocator.alloc(?u32, intactVertex.len);
        defer allocator.free(vertexMoved);
        for(0..vertexMoved.len) | q | vertexMoved[q] = null; // initialize to null
        var i_validFace:usize = 0; // Stores index of used-face
        var i_vertexSpot:usize = std.mem.indexOfScalar(bool, intactVertex, false) orelse intactVertex.len; // Stores unused spot in vertices which may be used to store a used-vertex
        var i_faceSpot:usize = std.mem.indexOfScalar(bool, intactFace, false) orelse intactFace.len; // Stores unused spot in indices which may be used to store a used-face

        // TODO: Make vertices are moved in array -> but values in indices are not changed -> change references in indices to new vertex index

        i = 0;
        while(i<faceCount):(i+=1){
            // ----- find valid face -----
            i_validFace = std.mem.indexOfScalarPos(bool, intactFace, i_validFace+1, true) orelse break; // Find intact face -> if no more to be found stop loop
            // while(!intactFace[i_validFace]):(i_validFace+=1){} i_validFace -= 1; // increment i_validFace until encountering a valid face
            const faceIndices = indices[i_validFace*3..][0..3];

            // ----- try to move vertices down -----
            for (faceIndices, 0..) | i_vertex, k | {
                if (vertexMoved[i_vertex]) |spot| { // If vertex has been moved before 
                    faceIndices[k] = spot; // replace indice reference
                } else{ // If vertex is in original position
                    if (i_vertex > i_vertexSpot) { // if there is a spot free in a lower index
                        vertexMoved[i_vertex] = @intCast(i_vertexSpot); // note where vertex is moving
                        faceIndices[k] = @intCast(i_vertexSpot); // move indice reference

                        intactVertex[i_vertex] = false; // remove vertex from current spot
                        intactVertex[i_vertexSpot] = true;

                        @memcpy(vertices[i_vertexSpot*3..][0..3], vertices[i_vertex*3..][0..3]); // move vertex to free spot
                        i_vertexSpot = std.mem.indexOfScalarPos(bool, intactVertex, i_vertexSpot+1, false) orelse intactVertex.len; // look for next free spot
                    }
                }

            }
            
            // std.debug.print("i_faceSpot/i_validFace: {}/{}\n", .{i_faceSpot, i_validFace});

            // ----- try to move face down in indices -----
            if(i_faceSpot<i_validFace){ // if there is a spot free in a lower index
                intactFace[i_validFace] = false; // Remove face from current spot
                intactFace[i_faceSpot] = true;
                @memcpy(indices[i_faceSpot*3..][0..3], faceIndices); // move face
                i_faceSpot = std.mem.indexOfScalarPos(bool, intactFace, i_faceSpot+1, false) orelse intactFace.len; // look for next free spot
            }
        }

        // ----- trim memory to used-portion -----
        mesh.vertexCount = @intCast(i_vertexSpot); // Index of first unused memory spot
        mesh.triangleCount = @intCast(i_faceSpot);
        mesh.vertices = try allocator.realloc(mesh.vertices, mesh.vertexCount*3);
        mesh.indices = try allocator.realloc(mesh.indices, mesh.triangleCount*3);
    } 

    const SurrogateLink = struct{
        originalIndex: u32,
        value: f32,
    };

    fn surrogateCompare(_:void, s1: SurrogateLink, s2: SurrogateLink) bool {
        return s1.value < s2.value;
    }

    fn errInfoCompare(_: void, e1: EdgeErrInfo, e2: EdgeErrInfo) bool {
        return e1.err < e2.err;
    }

    fn flagErrCompare(itemError: f32, flag: FlagItem) std.math.Order {
        const a = flag.err;
        
        if(itemError == a) {
            return .eq;
        } else if (itemError < a) {
            return .lt;
        } else if (itemError > a) {
            return .gt;
        } else {
            unreachable;
        }
    }

    fn cutOffCompare(cutOffValue: f32, item: SurrogateLink) std.math.Order {
        const a = item.value;
        
        if(cutOffValue == a) {
            return .eq;
        } else if (cutOffValue < a) {
            return .lt;
        } else if (cutOffValue > a) {
            return .gt;
        } else {
            unreachable;
        }
    }

    fn edgeChangeCompare(_: void, e1: AlteredEdgeErrorInfo, e2: AlteredEdgeErrorInfo) bool {
        return e1.edgeErrorInfo.err < e2.edgeErrorInfo.err;
    }

    /// Returns false if not all flags are present in linked Chain
    fn chainCheck(self: LinkedErrors, HE: []HalfEdge) !void{
        // const flags = self.valueFlags.items;
        
        // var prevFlag:isize = -1;
        // var j:usize = flags[0].index;
        // while(self.linkedList[j].i_next != self.linkedList.len):(j = self.linkedList[j].i_next){ // Go through linked list
        //     for(flags, 0..) | flag, k | { // check if current item is in flags
        //         if (j == flag.index){
        //             // std.debug.print("| <- [{}]\n", .{k});
        //             if(k != @as(usize, @intCast(prevFlag + 1))) { // If a flag was skipped -> return false
        //                 std.debug.print("flag[{}] is larger than expected [{}]\n", .{k, prevFlag+1});
        //                 self.printChain(@intCast(k));
        //                 return false;
        //             }
        //             prevFlag +=1;
        //         }
        //     }
        // }
        // return true;

        var i:u32 = self.valueFlags.items[0].index;
        var debug: usize = 0;
        while(i != self.linkEnd):(i = self.linkedList[i].i_next){
            debug+=1;
            if(debug > HE.len) return error.Unexpected;
            // std.debug.print("{}|", .{i});
            // ===== Check twins =====
            if(i != HE[HE[i].twin].twin) {
                std.debug.print("halfEdges[{0}].twin = {1}\nhalfEdges[{1}].twin = {2} != {0}\n", .{i, HE[i].twin, HE[HE[i].twin].twin});
                return error.Unexpected;
            }

            // ===== Check next =====
            if(i != HE[HE[i].next].prev) return error.Unexpected;

            // ===== Check previous =====
            if(i != HE[HE[i].prev].next) return error.Unexpected;

            // ===== Check face validity =====
            if(HE[i].origin == HE[HE[i].next].origin or HE[i].origin == HE[HE[i].prev].origin) {
                std.debug.print("HalfEdges[{}].origin = {}\n", .{i, HE[i].origin});
                if(HE[i].origin == HE[HE[i].next].origin){
                    std.debug.print("HalfEdges[{0}].next = {1} and HalfEdges[{1}].origin = {2} == {3}\n", .{i, HE[i].next, HE[HE[i].next].origin, HE[i].origin});
                } else {
                    std.debug.print("HalfEdges[{0}].next = {1} and HalfEdges[{1}].origin = {2} == {3}\n", .{i, HE[i].prev, HE[HE[i].prev].origin, HE[i].origin});
                }
                return error.Unexpected;
            }
        }


        // std.debug.print("\n", .{});
    }

    pub fn inChain(self: LinkedErrors, edgeInd: u32) bool {
        
        var i = self.valueFlags.items[0].index;
        while(i != self.linkEnd):(i = self.linkedList[i].i_next){
            if(i == edgeInd) return true;
        }
        return false;

    }

    fn printChain(self:LinkedErrors, maxFlag: u32) void {
        const LL = self.linkedList;
        const flags = self.valueFlags.items;

        var i = self.valueFlags.items[0].index;
        while(LL[i].i_next != LL.len):(i = LL[i].i_next){
            std.debug.print("|{}", .{i});
            for (flags, 0..) |flag, k| {
                if(i == flag.index) {
                    std.debug.print("<-[{}]\n", .{k});
                    if (k >= maxFlag) return;
                    break;
                }
            }
        }
    }

    /// Print first `n` items in `self.linkedList`
    fn printChainItems(self:LinkedErrors, n: usize) void {
        const LL = self.linkedList;

        var i = self.valueFlags.items[0].index;
        var j:usize = 0;
        std.debug.print("Item in Chain |  Edge  |  error\n", .{});
        while(LL[i].i_next != LL.len):(i = LL[i].i_next){
            std.debug.print("{d:<13} | {d:^6} | {d:^6.6}\n", .{j, i, self.edgeErrors[i].err});
            j+=1;
            if(j >= n) break;
        }
    }
};

/// Struct to store raw mesh data
pub const PlaceHolderMesh = struct {
    // Useful to store large amount of indices as it uses u32 instead of u16
    allocator: Allocator,
    indices: []u32 = undefined,
    vertices: []f32 = undefined,
    normals: []f32 = undefined,
    texcoords: []f32 = undefined,
    triangleCount: u32 = undefined,
    vertexCount: u32 = undefined,
    boundingBox: BoundingBox = undefined,

    /// gets a `BoundingBox` type of self.
    pub fn getBoundingBox(self: PlaceHolderMesh) BoundingBox {
        // Get min and max vertex to construct bounds (AABB)
        var minVertex: @Vector(3, f32) = undefined;
        var maxVertex: @Vector(3, f32) = undefined;

        if (self.vertices.len != 0) {
            minVertex = self.vertices[0..3].*;
            maxVertex = self.vertices[0..3].*;

            var i: usize = 1;
            while (i < self.vertexCount) : (i += 1) {
                const testVector: @Vector(3, f32) = self.vertices[i * 3 ..][0..3].*;

                minVertex = @min(minVertex, testVector);
                maxVertex = @max(maxVertex, testVector);
            }
        }

        // Create the bounding box
        const box: BoundingBox = .{
            .min = .{ .x = minVertex[0], .y = minVertex[1], .z = minVertex[2] },
            .max = .{ .x = maxVertex[0], .y = maxVertex[1], .z = maxVertex[2] },
        };

        return box;
    }

    /// Returns a zune.Mesh type, deinit self if `doDeinit` is `true`. Assumes both normals and uv's are defined
    pub fn toMesh(self: PlaceHolderMesh, resourceManager: *zune.graphics.ResourceManager, meshName: OfMeshName, doDeinit: bool) !*zune.graphics.Mesh {

        // ----- Create rl.Mesh to upload and return -----
        const data = try self.interweave();
        const result = switch (meshName) {
            .meshName => |name| try resourceManager.createMesh(name, data, self.indices, 8),
            .meshPrefix => |prefix| try resourceManager.autoCreateMesh(prefix, data, self.indices, 8),
        };
        if (doDeinit) self.deinit();
        self.allocator.free(data);
        return result;
    }

    fn interweave(self: PlaceHolderMesh) ![]f32 {
        const vertexCount = self.vertexCount;
        const b: usize = 8;

        const data = try self.allocator.alloc(f32, @as(usize, @intCast(vertexCount)) * b);

        var i: usize = 0;
        while (i < vertexCount) : (i += 1) {
            @memcpy(data[i * b ..][0..3], self.vertices[i * 3 ..][0..3]);
            @memcpy(data[i * b ..][3..5], self.texcoords[i * 2 ..][0..2]);
            @memcpy(data[i * b ..][5..8], self.normals[i * 3 ..][0..3]);
        }

        return data;
    }

    /// Frees all slices stored in struct
    /// ASSUMES ALL FIELDS HAVE BEEN FILLED & ALLOCATOR IS PRESENT
    pub fn deinit(self: PlaceHolderMesh) void {
        self.allocator.free(self.indices);
        self.allocator.free(self.vertices);
        self.allocator.free(self.normals);
        self.allocator.free(self.texcoords);
    }
};

/// Holds axis-aligned maximums of points
pub const BoundingBox = struct { min: Vec3(f32), max: Vec3(f32) };

const LinkedItem = struct {
    i_prev: u32,
    value: f32,
    i_next: u32,
};

const FlagItem = struct {
    index: u32,
    err: f32,
};

/// A struct containing a halfedge and an index
const AlteredEdgeErrorInfo = struct {
    index: u32,
    edgeErrorInfo: EdgeErrInfo,
};

const EdgeErrInfo = struct {
    // edge:u32,
    err:f32,
    newPos: [3]f32,
};

const HalfEdge = struct {
    origin: u32,
    twin: u32,
    next: u32,
    prev: u32,
    i_face: ?u32 = null,
};

pub const CollapsingFaceTwins = struct {
    // Edge 1
    outer1: u32, // stores edge outside collapsing-edge-face
    inner1: u32, // stores edge inside collapsing-edge-face
    // Edge 2
    outer2: u32,
    inner2: u32,
};

const FaceNormalInfo = struct {
    i_face: u32,
    normal: [3]f32,
};

fn print_RM_4Mat(m:[16]f32) void {
    for(m, 0..) | m_, i | {
        if(@rem(i, 4) == 0) std.debug.print("\n", .{});
        std.debug.print("{d:6} ", .{m_});
    } 
    std.debug.print("\n", .{});
}

fn print_CM_4Mat(m:[16]f32) void {
    for(0..4) | i | {
        std.debug.print("{d:6} {d:6} {d:6} {d:6} \n", .{m[0+i], m[4+i], m[8+i], m[12+i], });
    } 
}

fn print_CM_4Matd(m:[16]f64) void {
    for(0..4) | i | {
        for([_]f64{m[0+i], m[4+i], m[8+i], m[12+i]}) | v|{
            print_66_f64(v);
            std.debug.print(" ", .{});
        }
        std.debug.print("\n", .{});
    } 
}

fn print_66_f64(v: f64) void {
    const ints = @floor(v);
    const decimals = @round(@rem(@abs(v),1)*std.math.pow(f64, 10, 6));

    std.debug.print("{d:>6}.{d:<6}", .{ints, decimals});
}