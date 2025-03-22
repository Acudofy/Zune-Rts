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


/// Returns the index of an item with `itemPtr` in an array given a pointer to the first item in said array `basePtr`.
pub inline fn indexOfPtr(comptime T: type, basePtr: *T, itemPtr: *T) usize {
    return (@intFromPtr(itemPtr)-@intFromPtr(basePtr))/@sizeOf(T);
}

// ======================================
// Structs
// ======================================

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