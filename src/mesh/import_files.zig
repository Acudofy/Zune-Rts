const std = @import("std");
const zune = @import("zune");
const zmath = zune.math;
const math = @import("../math.zig");

const PHMesh = @import("processing.zig").PlaceHolderMesh;

const Allocator = std.mem.Allocator;
const Vec3 = zmath.Vec3;

const fileError = error{
    EndOfStream,
    VertexError,
    UVError,
    IndiceError,
    InvalidReaderMovement,
    InvalidDataType,
    InvalidContext,
    PrecederOnBoundary,
};

const ParseFun = union(enum) { intParse: @TypeOf(std.fmt.parseInt), floatParse: @TypeOf(std.fmt.parseFloat) };

const OfMesh = union(enum) { zMesh: *zune.graphics.Mesh, phMesh: PHMesh };
pub const OfMeshName = union(enum) {meshName: []const u8, meshPrefix: []const u8}; 

// ===== Thin wrappers for importObj function =====

pub fn importZMeshObj(resourceManager: *zune.graphics.ResourceManager, obj_file: []const u8, meshName: []const u8) !*zune.graphics.Mesh {
    const result = try importObj(resourceManager, obj_file, meshName, true);
    return result.zMesh;
}

pub fn importPHMeshObj(resourceManager: *zune.graphics.ResourceManager, obj_file: []const u8) !PHMesh {
    const result = try importObj(resourceManager, obj_file, "", false);
    return result.phMesh;
}

/// Import .obj file to OfMesh depending on toMesh
fn importObj(resourceManager: *zune.graphics.ResourceManager, obj_file: []const u8, meshName: []const u8, toMesh: bool) !OfMesh {
    // ===== Initialize variables =====
    const allocator = resourceManager.allocator;
    const linePreceders = [_][]const u8{"v ", "vt ", "vn ", "f "};
    var i_lp:usize = 0;
    std.debug.print("Started import...\n", .{});
    // ----- find file -----
    const file = try std.fs.cwd().openFile(obj_file, .{});
    std.debug.print("Opened file...\n", .{});
    // Create buffered reader -> Stores sections of file in buffer to minimize calls to system
    var buffered = std.io.bufferedReader(file.reader());

    // Create buffer to store lines
    var lineBuf = std.ArrayList(u8).init(allocator);
    // errdefer lineBuf.deinit();
    defer lineBuf.deinit();

    // ===== Read vertices =====
    const verticeInfo: readInfo(f32) =
        try storeLineInfo(allocator, f32, &buffered, "v ", .{ .lineBuf = &lineBuf });
    defer allocator.free(verticeInfo.values);

    const vertexCount = @divExact(verticeInfo.values.len, verticeInfo.lineValueCount);

    std.debug.print("read vertices...\n", .{});


    // ===== Read UVs (optional) =====
    i_lp = 1;
    var i_del = try sneakToEither(&buffered, linePreceders[i_lp..]);

    const uvInfo: ?readInfo(f32) = switch(i_del == 0) { // delimiter of uv was found
        true => try storeLineInfo(allocator, f32, &buffered, "vt ", .{ .lineBuf = &lineBuf, .readCapacity = vertexCount }),
        false => null,
    }; 
    defer if (uvInfo) | info | allocator.free(info.values);
    // ----- Sanity check -----

    if (uvInfo) | info | {
        std.debug.print("read UVs...\n", .{});
        if (info.lineValueCount < 2) return fileError.InvalidDataType;
    } else std.debug.print("no UVs found...\n", .{});


    // ===== Read vertexNormals if present =====
    i_lp = 2;
    i_del = try sneakToEither(&buffered, linePreceders[i_lp..]);
    const normalsExist = i_del == 0;

    const vertexNormalsInfo: ?readInfo(f32) = switch(normalsExist) { // delimiter of uv was found
        true => try storeLineInfo(allocator, f32, &buffered, "vn ", .{ .lineBuf = &lineBuf, .readCapacity = vertexCount }),
        false => null,
    }; 
    defer if (vertexNormalsInfo) | info | allocator.free(info.values);

    // ----- Sanity check -----
    if (vertexNormalsInfo) | info | {
        std.debug.print("read normals...\n", .{});
        if (info.lineValueCount < 3) return fileError.InvalidDataType;
    } else std.debug.print("no normals found...\n", .{});

    // ===== Read indices =====
    const indiceInfo: readInfo(u32) =
        try storeLineInfo(allocator, u32, &buffered, "f ", .{
            .lineBuf = &lineBuf,
            .readCapacity = vertexCount,
            .subdivider = '/',
            .lineValueCount = 12,
        });
    // errdefer allocator.free(indiceInfo.values);
    defer allocator.free(indiceInfo.values);

    const faceCount = @divExact(indiceInfo.values.len, indiceInfo.lineValueCount); // Count of lines
    const faceVertexCount:usize = switch (indiceInfo.lineValueCount) {
        3 => 3,
        4 => 4,
        6 => 3,
        8 => 4,
        9 => 3,
        12 => 4,
        else => return fileError.InvalidDataType,
    };

    const indiceLen: usize = @divExact(indiceInfo.values.len, faceCount * faceVertexCount); // Length of indice 1: 1 2 3, 2: 1/1 2/2 3/3, etc.

    // ----- sanity checks -----
    if (indiceLen == 3 and !normalsExist) return fileError.InvalidDataType; // vertex normals are expected by indices but not present
    if (std.mem.containsAtLeastScalar(u32, indiceInfo.values, 1, 0)) return fileError.InvalidDataType; // No uv's are provided

    std.debug.print("read indices...\n", .{});

    // ===== Create indices =====
    // ----- Vertex -----
    const triangleCount: usize = if (faceVertexCount == 3) faceCount else if (faceVertexCount == 4) faceCount * 2 else return fileError.InvalidDataType;
    const indiceCount: usize = triangleCount * 3;

    // ----- Ensure faces are triangular -----
    const triIndices = try allocator.alloc(u32, indiceCount * indiceLen);
    errdefer allocator.free(triIndices);
    defer allocator.free(triIndices);
    if (faceVertexCount == 4) {
        var i: usize = 0;
        const triStepSize = 6 * indiceLen; // 2 triangles with 3 vertices
        const quadStepSize = 4 * indiceLen; // 1 quadralateral with 4 vertices
        while (i < faceCount) : (i += 1) {
            // triangle 1
            @memcpy(triIndices[i * triStepSize ..][0 .. 3 * indiceLen], indiceInfo.values[i * quadStepSize ..][0 .. 3 * indiceLen]);

            // triangle 2
            @memcpy(triIndices[i * triStepSize ..][3 * indiceLen .. 5 * indiceLen], indiceInfo.values[i * quadStepSize ..][2 * indiceLen .. quadStepSize]);
            @memcpy(triIndices[i * triStepSize ..][5 * indiceLen .. 6 * indiceLen], indiceInfo.values[i * quadStepSize ..][0..indiceLen]);
        }
        std.debug.print("split quadraliteral indices...\n", .{});
    } else {
        @memcpy(triIndices, indiceInfo.values);
        std.debug.print("copied triangular indices...\n", .{});
    }
    for (0..triIndices.len) |i| triIndices[i] -= 1; // Make indices start from 0

    // ===== Create meshes =====
    switch (toMesh) {
        false => {
            const result = try assemblePHMesh(allocator, .{
                .triangleCount = triangleCount,
                .indiceCount = indiceCount,
                .indiceLen = indiceLen,
                .triIndices = triIndices,
            }, .{
                .vertexCount = vertexCount,
                .verticeInfo = verticeInfo,
            }, uvInfo, vertexNormalsInfo, normalsExist);
            return .{ .phMesh = result };
        },
        true => {
            const zMeshComponents = try assembleZMesh(allocator, .{
                .triangleCount = triangleCount,
                .indiceCount = indiceCount,
                .indiceLen = indiceLen,
                .triIndices = triIndices,
            }, .{
                .vertexCount = vertexCount,
                .verticeInfo = verticeInfo,
            }, uvInfo, vertexNormalsInfo, normalsExist);

            const result = try resourceManager.createMesh(meshName, zMeshComponents.data, zMeshComponents.indices, true);
            std.debug.print("Uploaded mesh...\n", .{});
            allocator.free(zMeshComponents.data);
            allocator.free(zMeshComponents.indices);

            return .{ .zMesh = result };
        },
    }
}

const IndiceContext = struct {
    triangleCount: usize,
    indiceCount: usize,
    indiceLen: usize,
    triIndices: []u32,
};

const VertexContext = struct {
    vertexCount: usize,
    verticeInfo: readInfo(f32),
};

fn assemblePHMesh(allocator: Allocator, indiceContext: IndiceContext, vertexContext: VertexContext, uvInfo: ?readInfo(f32), vertexNormalsInfo: ?readInfo(f32), hasNormals: bool) !PHMesh {
    // ===== unpack contexts =====
    const indiceLen = indiceContext.indiceLen;
    const indiceCount = indiceContext.indiceCount;
    const triIndices = indiceContext.triIndices;
    const triangleCount = indiceContext.triangleCount;

    const vertexCount = vertexContext.vertexCount;
    const verticeInfo: readInfo(f32) = vertexContext.verticeInfo;

    // ===== Create phMesh data structure and store read values =====
    const maxVertexCount = triangleCount*3; // a vertex for each index
    var vertices = try allocator.alloc(f32, maxVertexCount * 3); // Max length -> vertices may be duplicated if uv is different for face
    var uv: []f32 = if (uvInfo != null) try allocator.alloc(f32, maxVertexCount * 2) else undefined;
    var normals: []f32 = try allocator.alloc(f32, maxVertexCount * 3);

    const indices = try allocator.alloc(u32, indiceCount); // Final vertex indices in form 1 2 3 | 2 3 4 etc.

    // ----- Create auxilirary variables -----
    const uniqueIndice = try allocator.alloc(u32, vertexCount*indiceLen); // Scales with original vertex count -> stores only initial vertex' indice-set e.g. '1/2/3' (2/3/4 4/5/6)
    const uniqueIndex = try allocator.alloc(u32, vertexCount);
    const uniqueFound = try allocator.alloc(bool, vertexCount);
    defer allocator.free(uniqueIndice);
    defer allocator.free(uniqueIndex);
    defer allocator.free(uniqueFound);

    // ----- Start storing read-values -----
    var n: u32 = 0; // count of stored vertices
    var i: usize = 0; // count of reformated indices
    while (i < triangleCount * 3) : (i += 1) {
        const indice = triIndices[i * indiceLen ..][0..indiceLen];
        const vertexInd = indice[0];
        // var vertexUnique = vertexUniques[vertexInd];

        if (!uniqueFound[vertexInd]) { // if vertex index has not been found yet -> store vertex + metaData
            // ----- Make unique vertex entry -----
            uniqueFound[vertexInd] = true;
            uniqueIndex[vertexInd] = n;
            @memcpy(uniqueIndice[vertexInd * indiceLen ..][0..indiceLen], indice);

            // ----- Copy values to new containers -----
            @memcpy(vertices[n*3..][0..3], verticeInfo.values[vertexInd * verticeInfo.lineValueCount..][0..3]); // vertex
            if (uvInfo) | uvInf | @memcpy(uv[n*2 ..][0..2], uvInf.values[indice[1] * uvInf.lineValueCount ..][0..2]); // uv
            if (vertexNormalsInfo) |normalsInfo| @memcpy(normals[n*3 ..][0..3], normalsInfo.values[indice[2] * normalsInfo.lineValueCount ..][0..3]); // normals

            // ----- Store indicex -----
            indices[i] = n;

            n += 1;
        } else if (std.mem.eql(u32, uniqueIndice[vertexInd * indiceLen ..][0..indiceLen], indice)) { // vertex has already been found, with the same properties
            indices[i] = uniqueIndex[vertexInd];

        } else { // Vertex has been found, but with different properties
            // ----- Copy values to new containers -----
            @memcpy(vertices[n*3..][0..3], verticeInfo.values[vertexInd * verticeInfo.lineValueCount..][0..3]); // vertex
            if (uvInfo) | uvInf | @memcpy(uv[n*2 ..][0..2], uvInf.values[indice[1] * uvInf.lineValueCount ..][0..2]); // uv
            if (vertexNormalsInfo) |normalsInfo| @memcpy(normals[n*3 ..][0..3], normalsInfo.values[indice[2] * normalsInfo.lineValueCount ..][0..3]); // normals
            
            // ----- Store indicex -----
            indices[i] = n;

            n += 1;
        }
    }
    std.debug.print("Made Data struct for phMesh...\n", .{});

    // ===== Create Normals if not present =====
    if (hasNormals) {
        // ----- Create constants -----
        const faceNormals = try allocator.alloc(Vec3(f32), triangleCount);
        defer allocator.free(faceNormals);

        // ----- Find face normals -----
        i = 0;
        while (i < triangleCount) : (i += 1) {
            const i_a: u32 = indices[i * 3];
            const i_b: u32 = indices[i * 3 + 1];
            const i_c: u32 = indices[i * 3 + 2];

            const v1: Vec3(f32) = Vec3(f32){ .x = vertices[i_a * 3], .y = vertices[i_a * 3 + 1], .z = vertices[i_a * 3 + 2] };
            const v2: Vec3(f32) = Vec3(f32){ .x = vertices[i_b * 3], .y = vertices[i_b * 3 + 1], .z = vertices[i_b * 3 + 2] };
            const v3: Vec3(f32) = Vec3(f32){ .x = vertices[i_c * 3], .y = vertices[i_c * 3 + 1], .z = vertices[i_c * 3 + 2] };

            faceNormals[i] = v2.subtract(v1).cross(v3.subtract(v1));
        }

        // ----- Find vertice normals -----
        i = 0;
        while (i < triangleCount) : (i += 1) {
            const faceNormal = faceNormals[i]; // Find normal of face

            for (indices[i * 3 .. i * 3 + 2]) |Iv| {
                // Add normal to vertex-normals
                normals[Iv * 3] += faceNormal.x;
                normals[Iv * 3 + 1] += faceNormal.y;
                normals[Iv * 3 + 2] += faceNormal.z;
            }
        }

        // ----- Normalize vertex normals -----
        i = 0;
        while (i < vertexCount) : (i += 1) {
            math.vec3normalize(normals[i * 3 ..][0..3]);
        }
        std.debug.print("Created normals...\n", .{});
    }

    // ===== Shorten allocated memory =====
    return PHMesh{
        .allocator = allocator,
        .indices = indices,
        .vertices = try allocator.realloc(vertices, n*3),
        .texcoords = try allocator.realloc(uv, n*2),
        .normals = try allocator.realloc(normals, n*3),
        .triangleCount = @intCast(triangleCount),
        .vertexCount = n,
    };
}

fn assembleZMesh(allocator: Allocator, indiceContext: IndiceContext, vertexContext: VertexContext, uvInfo: ?readInfo(f32), vertexNormalsInfo: ?readInfo(f32), hasNormals: bool) !struct { data: []f32, indices: []u32 } {
    // ===== unpack contexts =====
    const indiceLen = indiceContext.indiceLen;
    const indiceCount = indiceContext.indiceCount;
    const triIndices = indiceContext.triIndices;
    const triangleCount = indiceContext.triangleCount;

    const vertexCount = vertexContext.vertexCount;
    const verticeInfo: readInfo(f32) = vertexContext.verticeInfo;

    // ===== Create zMesh data structure and store read values =====
    const b: usize = if(uvInfo != null) 8 else 6; // Amount of data points in single data-entree
    const Data = try allocator.alloc(f32, indiceCount * b);
    const indices = try allocator.alloc(u32, indiceCount); // Final vertex indices in form 1 2 3 | 2 3 4 etc.

    // ----- Create auxilirary variables -----
    const uniqueIndice = try allocator.alloc(u32, indiceLen * vertexCount);
    const uniqueIndex = try allocator.alloc(u32, vertexCount);
    const uniqueFound = try allocator.alloc(bool, vertexCount);
    defer allocator.free(uniqueIndice);
    defer allocator.free(uniqueIndex);
    defer allocator.free(uniqueFound);

    // ----- Start storing read-values -----
    var n: u32 = 0; // count of stored vertices
    var i: usize = 0; // count of reformated indices
    while (i < triangleCount * 3) : (i += 1) {
        const indice = triIndices[i * indiceLen ..][0..indiceLen];
        const vertexInd = indice[0];
        // var vertexUnique = vertexUniques[vertexInd];

        if (!uniqueFound[vertexInd]) { // if vertex index has not been found yet -> store vertex + metaData
            // ----- Make unique vertex entry -----
            uniqueFound[vertexInd] = true;
            uniqueIndex[vertexInd] = n;
            @memcpy(uniqueIndice[vertexInd * indiceLen ..][0..indiceLen], indice);

            // ----- Copy values to new containers -----
            @memcpy(Data[n * b ..][0..3], verticeInfo.values[vertexInd * verticeInfo.lineValueCount ..][0..3]); // vertex
            if (uvInfo) | uvInf | {
                @memcpy(Data[n * b ..][3..5], uvInf.values[indice[1] * uvInf.lineValueCount ..][0..2]); // uv
                if (vertexNormalsInfo) |normalsInfo| @memcpy(Data[n * b ..][5..8], normalsInfo.values[indice[2] * 3 ..][0..3]); // normals
            } else{
                if (vertexNormalsInfo) |normalsInfo| @memcpy(Data[n * b ..][3..6], normalsInfo.values[indice[2] * 3 ..][0..3]); // normals
            }

            // ----- Store indicex -----
            indices[i] = n;

            n += 1;
        } else if (std.mem.eql(u32, uniqueIndice[vertexInd * indiceLen ..][0..indiceLen], indice)) { // vertex has already been found, but has the same properties
            indices[i] = uniqueIndex[vertexInd];
        } else { // Vertex has been found, but with different properties
            // ----- Copy values to new containers -----
            @memcpy(Data[n * b ..][0..3], verticeInfo.values[vertexInd * verticeInfo.lineValueCount ..][0..3]); // vertex
            if (uvInfo) | uvInf | {
                @memcpy(Data[n * b ..][3..5], uvInf.values[indice[1] * uvInf.lineValueCount ..][0..2]); // uv
                if (vertexNormalsInfo) |normalsInfo| @memcpy(Data[n * b ..][5..8], normalsInfo.values[indice[2] * 3 ..][0..3]); // normals
            } else {
                if (vertexNormalsInfo) |normalsInfo| @memcpy(Data[n * b ..][3..6], normalsInfo.values[indice[2] * 3 ..][0..3]); // normals
            }

            // ----- Store indicex -----
            indices[i] = n;

            n += 1;
        }
    }
    std.debug.print("Made Data struct for zMeshg...\n", .{});

    // ===== Create Normals if not present =====
    if (!hasNormals) {
        // ----- Find face normals -----
        const faceNormals = try allocator.alloc(Vec3(f32), triangleCount);
        defer allocator.free(faceNormals);

        i = 0;
        while (i < triangleCount) : (i += 1) {
            const i_a: u32 = indices[i * 3];
            const i_b: u32 = indices[i * 3 + 1];
            const i_c: u32 = indices[i * 3 + 2];

            const v1: Vec3(f32) = Vec3(f32){ .x = Data[i_a * b], .y = Data[i_a * b + 1], .z = Data[i_a * b + 2] };
            const v2: Vec3(f32) = Vec3(f32){ .x = Data[i_b * b], .y = Data[i_b * b + 1], .z = Data[i_b * b + 2] };
            const v3: Vec3(f32) = Vec3(f32){ .x = Data[i_c * b], .y = Data[i_c * b + 1], .z = Data[i_c * b + 2] };

            faceNormals[i] = v2.subtract(v1).cross(v3.subtract(v1));
        }

        // ----- Find vertex normals -----
        i = 0;
        const c: u8 = if(uvInfo != null) 5 else 3;
        while (i < triangleCount) : (i += 1) {
            const faceNormal = faceNormals[i]; // Find normal of face

            for (indices[i * 3 .. i * 3 + 2]) |Iv| {
                // Add normal to vertex-normals
                Data[Iv * b + c] += faceNormal.x;
                Data[Iv * b + c + 1] += faceNormal.y;
                Data[Iv * b + c + 2] += faceNormal.z;
            }
        }

        // ----- Normalize vertex normals -----
        i = 0;
        while (i < vertexCount) : (i += 1) {
            math.vec3normalize(Data[i * b + c .. ][0..3][0..]);
        }
        std.debug.print("Created normals...\n", .{});
    } else {
        std.debug.print("normals already existed...\n", .{});
    }

    // ===== Shorten allocated memory =====
    const new_vertexCount = n;
    std.debug.print("new_vertexCount: {}\n", .{new_vertexCount});
    const data: []f32 = try allocator.realloc(Data, new_vertexCount * b);
    return .{ .data = data, .indices = indices };
}

/// Context for `storeLineInfo`.
pub const StoreLineContext = struct {
    lineBuf: *std.ArrayList(u8), // stores line characters when file is being read
    readCapacity: usize = 30, // inital capacity of listArray which stores read values
    lineValueCount: usize = 10, // maximum amount of values to-be-read on a single line
    subdivider: ?u8 = null, // subdivider needed for e.g. "preceder|x0/x1/x2 y0/y1/y2 ...\n"
};

fn readInfo(T: type) type {
    return struct {
        values: []T,
        lineValueCount: usize,
    };
}

/// Returns values in file which are in subsequent lines, allongside the amount of values read in a single line.
/// Assumes lines are formated as follows: '`linePreceder`|value value ... value\n'
/// Makes use of a valuebuffer to minimize calls to `ArrayList(T).append()`.
///
/// `bufferedReader` should be reading the file.
/// `lineBuf` in `context` is used to store lines.
/// `lineValueCount` in `context` should be the maximum expected amount of values in a line.
pub fn storeLineInfo(allocator: Allocator, comptime T: type, bufferedReader: anytype, linePreceder: []const u8, context: StoreLineContext) !readInfo(T) {

    // ===== Initialize auxilirary variables =====
    const valueBuf = try allocator.alloc(T, context.lineValueCount); // Used to store before appending to reduce calls to array.append
    defer allocator.free(valueBuf);
    var valueBufWriter = sliceWriter(T).init(valueBuf);
    var lineBuf: *std.ArrayList(u8) = context.lineBuf;
    const subdivider = context.subdivider;

    var array = try std.ArrayList(T).initCapacity(allocator, context.readCapacity);

    const parseFun = switch (@typeInfo(T)) {
        .int => parseInt(T, 10),
        .comptime_int => parseInt(T, 10),
        .float => std.fmt.parseFloat,
        .comptime_float => std.fmt.parseFloat,
        else => return fileError.InvalidDataType,
    };

    // ===== skip to vertex data =====
    try readUntilStr(bufferedReader, linePreceder);

    const preceder: []const u8 = switch (try indexUntilnot(bufferedReader, ' ')) {
        0 => try allocator.dupe(u8, linePreceder),
        else => |extraSpaces| smtn: {
            var pre = try allocator.alloc(u8, extraSpaces + linePreceder.len);
            @memcpy(pre[0..linePreceder.len], linePreceder);
            for (0..extraSpaces) |i| pre[linePreceder.len + i] = ' ';
            break :smtn pre;
        },
    };
    defer allocator.free(preceder);

    // ===== Load in data =====
    var lineLen = try readUntilDelimiter(bufferedReader, lineBuf.writer(), '\n', false);
    var inLineBlock = true; // Reader is inside block of lines with 'linePreceder'
    var debug: usize = 0;
    while (inLineBlock) : (debug += 1) {
        // ----- Prepare reading of line -----
        var bufStart: usize = 0;
        valueBufWriter.reset();

        // ----- convert data in line -----
        const items = lineBuf.items;
        while (std.mem.indexOfScalar(u8, items[bufStart..lineLen], ' ')) |valueLen| { // Assume values are seperated by ' '
            // Read value out of buffer
            try convertFun(T, items[bufStart..][0..valueLen], parseFun, &valueBufWriter, subdivider);

            // Go to next value in buffer
            bufStart += valueLen + 1; // Skip ' '
        }
        // Load last line
        if (bufStart != lineLen) try convertFun(T, items[bufStart..lineLen], parseFun, &valueBufWriter, subdivider);

        // ----- store values in buffer to array -----
        try array.appendSlice(valueBuf[0..valueBufWriter.i]);

        // ----- Load in new line -----
        lineBuf.clearRetainingCapacity();
        if (!try checkPreceder(bufferedReader, preceder)) { // check if next line starts with linePreceder
            inLineBlock = false; // if not exit
            break;
        }
        lineLen = try readUntilDelimiter(bufferedReader, lineBuf.writer(), '\n', false); // Store line Length of next line
    }

    // ===== Return values =====
    return .{ .values = try array.toOwnedSlice(), .lineValueCount = valueBufWriter.i };
}

/// Moves buffered over memory and return how many characters have been skipped
fn indexUntilnot(buffered: anytype, delimiter: u8) !usize {
    var i: usize = 0;
    while (true) : (i += 1) {
        // const start = buffered.start;
        if (buffered.buf[buffered.start + i] != delimiter) {
            buffered.start += i;
            return i;
        } else {
            if (buffered.buf[buffered.start + i] == buffered.end - 1) {
                // At the end
                try refreshBuffer(buffered);
            }
        }
    }
}

/// Check if first character(s) in buffer are the same as preceder
/// Buffer moves over memory if preceder is found.
fn checkPreceder(buffered: anytype, preceder: []const u8) !bool {
    // ===== Single character compare =====
    if (preceder.len == 1) {
        const result: bool = buffered.buf[buffered.start] == preceder[0];
        if (result) try increaseStart(buffered); // skip preceder if preceder is valid else return false
        return result;
    }

    // ===== Multi-character compare =====
    const precederEnd = buffered.start + preceder.len;
    if (precederEnd <= buffered.end) { // if preceder should fall within buffer
        const result = std.mem.eql(u8, preceder, buffered.buf[buffered.start..precederEnd]);
        if (result) {
            if (precederEnd == buffered.end) { // if buffer is completely read
                try refreshBuffer(buffered); // refresh buffer
            } else {
                buffered.start += preceder.len;
            }
        }
        return result;
    } else { // preceder is split between current buffer and next to-be-loaded buffer
        const overlap: usize = buffered.end - buffered.start;

        // ----- compare section 1 -----
        var precederFound: bool = true;
        precederFound = precederFound and std.mem.eql(u8, preceder[0..overlap], buffered.buf[buffered.start..buffered.end]);

        if (precederFound) {

            // // ----- copy reader to avoid buffer being changed -----
            // // buffered.unbuffered_reader.

            // ----- load next buffer -----
            try (refreshBuffer(buffered) catch |err| switch (err) {
                fileError.EndOfStream => return false,
                else => err,
            });

            // ----- compare section 2 -----
            precederFound = precederFound and std.mem.eql(u8, preceder[overlap..], buffered.buf[0 .. preceder.len - overlap]);

            // ----- increment buffer.start -----
            buffered.start += preceder.len - overlap; // Skip preceder

            if (!precederFound) return fileError.PrecederOnBoundary;
        }
        return precederFound;
    }
}

fn increaseStart(buffered: anytype) !void {
    if (buffered.start + 1 == buffered.end) { // Increasing would go outside of buffer length
        // Reload buffered reader with new data
        try refreshBuffer(buffered);
    } else {
        buffered.start += 1;
    }
}

fn refreshBuffer(buffered: anytype) !void {
    const n: usize = try buffered.unbuffered_reader.read(buffered.buf[0..]);
    if (n == 0) return fileError.EndOfStream; // Buffer could not be refilled

    buffered.start = 0;
    buffered.end = n;
}

pub fn readUntilDelimiter(buffered: anytype, writer: anytype, delimiter: u8, p: bool) !usize {
    if (p) std.debug.print("-----------\n", .{});
    var len: usize = 0;
    var preBufChar: u8 = undefined;
    while (true) {
        const start = buffered.start;
        if (std.mem.indexOfScalar(u8, buffered.buf[start..buffered.end], delimiter)) |pos| {
            if (pos == 0) {
                len += 0; // Edge-case -> first item is delimiter -> return 0
                buffered.start += 1;
                if (preBufChar == 13) {
                    return len - 1;
                } else {
                    return len;
                }
            }
            if (p) {
                std.debug.print("pos: {}\n", .{pos});
                std.debug.print("buffered.buf: {s}|\n", .{buffered.buf[start .. start + pos - 1]});
            }
            len += pos; // update read-length

            // found delimiter
            try writer.writeAll(buffered.buf[start .. start + pos]); // Write all till before delimiter

            buffered.start += pos + 1; // Set start after delimiter position
            if (buffered.buf[buffered.start - 2] == 13) { // If second-last character is CR
                return len - 1;
            } else {
                return len;
            }
        } else {
            if (p) std.debug.print("wrapped\n", .{});
            // No delimiter found -> write all
            try writer.writeAll(buffered.buf[start..buffered.end]);

            len = buffered.end - start;

            // refill buffer
            preBufChar = buffered.buf[buffered.end - 1];
            try refreshBuffer(buffered);
        }
    }
}

/// Move forward to a delimiter in `delimiters` and move buffered to just before it. Returns how manieth delimiter was found
pub fn sneakToEither(buffered: anytype, delimiters: []const[]const u8) !u8 {
    const searching: bool = true;
    while(searching){
        for(delimiters, 0..) | del, i | {
            if(try checkPreceder(buffered, del)){
                try moveStart(buffered, -@as(isize, @intCast(del.len)));
                return @intCast(i);
            }
        }
        try readUntil(buffered, '\n');
    }
}

/// progresses buffered until after certain delimiter
pub fn readUntil(buffered: anytype, delimiter: u8) !void {
    while (true) {
        const start = buffered.start;
        if (std.mem.indexOfScalar(u8, buffered.buf[start..buffered.end], delimiter)) |pos| {
            // found delimiter
            buffered.start += pos + 1; // Set start after delimiter position
            return;
        } else {
            // No delimiter found
            try refreshBuffer(buffered);
        }
    }
}

pub fn readUntilStr(buffered: anytype, delimiter: []const u8) !void {
    var precederFound = false;
    while (!precederFound) {
        try readUntil(buffered, delimiter[0]);
        precederFound = true;

        if (buffered.start == buffered.end) try refreshBuffer(buffered);

        // If line-preceder is multi-character check all characters
        if (delimiter.len > 1) {
            for (delimiter[1..]) |char| {
                if (buffered.buf[buffered.start] == char) {
                    try increaseStart(buffered);
                } else { // If character is unexpected
                    precederFound = false;
                }
            }
        }
    }
}

pub fn moveStart(buffered: anytype, movement: isize) !void {
    if (movement < 0) {
        if (buffered.start < -movement) {
            return fileError.InvalidReaderMovement;
        } // Too far back
        else {
            buffered.start -= @as(usize, @intCast(-movement));
        }
    } else {
        if (buffered.end - buffered.start <= movement) {
            return fileError.InvalidReaderMovement;
        } // Too far forward
        else {
            buffered.start += @as(usize, @intCast(movement));
        }
    }
}

const SliceWriterErr = error{outOfMemory};
pub fn sliceWriter(T: type) type {
    return struct {
        slice: []T,
        i: usize = 0,
        const Self = @This();

        pub fn init(slice: []T) Self {
            return .{ .slice = slice };
        }

        pub fn write(self: *Self, value: T) SliceWriterErr!void {
            if (self.i >= self.slice.len) return SliceWriterErr.outOfMemory;
            self.slice[self.i] = value;
            self.i += 1;
        }

        pub fn reset(self: *Self) void {
            self.i = 0;
        }
    };
}

/// Default to 0 if "" is passed in multi-value function
fn convertFun(T: type, value: []const u8, parseFun: anytype, valBufWriter: anytype, delimiter: ?u8) !void {
    if (delimiter) |del| {
        var i: usize = 0;
        var splitvalues = std.mem.splitScalar(u8, value, del);
        while (splitvalues.next()) |char| {
            if (char.len == 0) {
                try valBufWriter.write(0);
            } else {
                try valBufWriter.write(try parseFun(T, char));
            }
            i += 1;
        }
    } else {
        try valBufWriter.write(try parseFun(T, value));
    }
}

pub fn parseInt(Type: type, base: u8) fn (type, []const u8) std.fmt.ParseIntError!Type {
    return struct {
        fn intParse(T: type, str: []const u8) std.fmt.ParseIntError!T {
            return std.fmt.parseInt(T, str, base);
        }
    }.intParse;
}

// ================ DEPRICATED ===============
// fn passFunctionGen(T: type, parseFunction: anytype) *const fn ([]const u8, anytype) errorUnion!void {
//     return struct {
//         fn convertValue(str: []const u8, arrayWriter: anytype) errorUnion!void {

//             try arrayWriter.write(try parseFunction(T, str));
//         }
//     }.convertValue;
// }

// const errorUnion = std.fmt.ParseIntError || std.fmt.ParseFloatError || SliceWriterErr;
// fn splitFunctionGen(T: type, parseFunction: anytype) *const fn ([]const u8, anytype) errorUnion!void {
//     return struct {
//         fn splitFloats(str: []const u8, arrayWriter: anytype) errorUnion!void {
//             var i:usize = 0;
//             var splitvalues = std.mem.splitScalar(u8, str, '/');
//             while(splitvalues.next()) | char |{
//                 try arrayWriter.write(try parseFunction(T, char));
//                 i+=1;
//             }
//         }
//     }.splitFloats;
// }
