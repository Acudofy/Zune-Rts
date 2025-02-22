const std = @import("std");
const zune = @import("zune");
const zmath = zune.math;
const math = @import("math.zig");

const Allocator = std.mem.Allocator;

const fileError = error { EndOfStream,
                                VertexError,
                                UVError,
                                IndiceError,
                                InvalidReaderMovement,
                                InvalidDataType,};

/// Import .obj file. Excludes line 0
pub fn importObj (resourceManager: *zune.graphics.ResourceManager, obj_file: []const u8) !*zune.graphics.Mesh {
    // Take allocator from resourceManager
    const allocator = resourceManager.allocator;
    
    // Check if file exists first
    const file = try std.fs.cwd().openFile(obj_file, .{});

    var buffered = std.io.bufferedReader(file.reader()); // Create buffered reader -> Stores sections of file in buffer to minimize calls to system
    // var reader = buffered.reader();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Skip non-info-lines
    while(buffered.buf[buffered.start] != ' '){ // loop through v's until 'v '
        try readUntil(&buffered, 'v'); // Skip until first vector 
    }
    try moveStart(&buffered, -1);

    // ===== Store vertices =====
    var vertices = std.ArrayList(f32).init(allocator);
    defer vertices.deinit();
    var vertexCount: usize = 0;
    var verticeBuffer: [5]f32 = [_]f32{ 0 } ** 5;
    // var i:usize = 0;
    // var j:usize = 0;
    while(readUntilDelimiter(&buffered, buffer.writer(), '\n', false) catch | err | switch (err) {fileError.EndOfStream => null, else => return err,}) | len | {
        
        const items = buffer.items;
        if (items[0] != 'v' or items[1] != ' ') {
            // try moveStart(&buffered, -@as(isize, @intCast(len+2)));
            break; // If line depicts UV: 'v[t] ...' 
        }
        var pos: usize = undefined;
        var start:usize = 2; // after 'v ' in line
        var end:usize = undefined;


        pos = std.mem.indexOfScalar(u8, items[start..], ' ') orelse return fileError.VertexError;
        end = start + pos;
        verticeBuffer[0] = try std.fmt.parseFloat(f32, items[start..end]);
        start = end+1; // skip ' '
        
        pos = std.mem.indexOfScalar(u8, items[start..], ' ') orelse return fileError.VertexError;
        end = start + pos;
        verticeBuffer[1] = try std.fmt.parseFloat(f32, items[start..end]);
        // try vertices.append(try std.fmt.parseFloat(f32, items[start..end]));
        start = end+1; // skip ' '
        
        // Check for first ' ', but if not found-> no color or w given -> assume value is at end of line'... f32\n'
        pos = std.mem.indexOfScalar(u8, items[start..len], ' ') orelse len-start;
        end = start + pos;
        verticeBuffer[2] = try std.fmt.parseFloat(f32, items[start..end]);

        // try vertices.append(try std.fmt.parseFloat(f32, items[start..end]));
        // std.debug.print("[{}, {}]\n", .{start, end});
        try vertices.appendSlice(&verticeBuffer);
        buffer.clearRetainingCapacity(); // Clear buffer
        vertexCount += 1; // Count stored vertex
    }
    // std.debug.print("VertexCount: {}\n", .{vertexCount});
    const Vertices = try allocator.alloc(f32, vertexCount*5);
    errdefer allocator.free(Vertices);
    std.mem.copyForwards(f32, Vertices, vertices.items);

    // Make sure first read will return uv info
    
    if (buffer.items[0] == 'v' and buffer.items[1] == 't'){ // Current buffer stores uv
        try moveStart(&buffered, -1); // Align buffer to before \n character
    } else {
        // Skip non-info-lines
        while(buffered.buf[buffered.start] != 't'){ // loop through v's until 'vt'
            try readUntil(&buffered, 'v'); // Skip until 'v'
        }
        try moveStart(&buffered, -1);
    }


    // ===== Store UVs =====
    // const uvs = try allocator.alloc(f32, vertexCount*2); 
    // errdefer allocator.free(uvs);

    var i:usize = 0;
    while(readUntilDelimiter(&buffered, buffer.writer(), '\n', false) catch | err | switch (err) {fileError.EndOfStream => null, else => return err,}) | len | {
        const items = buffer.items;
        if (items[0] != 'v' or items[1] != 't') break; // If Vertex texture coordinate indices are starting to be defined

        var pos:usize = undefined;
        var start:usize = 3; // after 'vt ' in line
        // var end:usize = undefined;

        pos = std.mem.indexOfScalar(u8, items[start..], ' ') orelse return fileError.UVError;
        const end = start + pos;
        Vertices[i*5+3] = try std.fmt.parseFloat(f32, items[start..end]);
        start = end+1; // skip ' '
        // i+=1;

        const slice = items[start..len];

        Vertices[i*5+4] = try std.fmt.parseFloat(f32, slice);

        i+=1;
        buffer.clearRetainingCapacity(); // Clear buffer
    }
        std.debug.print("f\n", .{});

    // ===== Load indices =====
    // Assumes i/i j/j k/k format: indice of vertex and UV match
    var indices = std.ArrayList(u32).init(allocator);
    defer indices.deinit();

    var triangleCount:usize = 0;
    while(readUntilDelimiter(&buffered, buffer.writer(), '\n', false) catch | err | switch (err) {fileError.EndOfStream => null, else => return err,}) | _ | {
        const items = buffer.items;
        if (items[0] != 'f') break;// breaks when no indices are to be found

        var pos:usize = undefined;
        var start:usize = 2; // after 'f ' in line
        var end:usize = undefined;

        pos = std.mem.indexOfScalar(u8, items[start..], '/') orelse return fileError.IndiceError;
        end = start + pos;
        try indices.append(try std.fmt.parseInt(u32, items[start..end], 10)-1);

        start = end+pos+2; // skip '.../[value] ...'
        pos = std.mem.indexOfScalar(u8, items[start..], '/') orelse return fileError.IndiceError;
        end = start + pos;
        try indices.append(try std.fmt.parseInt(u32, items[start..end], 10)-1);
        
        start = end+pos+2;
        pos = std.mem.indexOfScalar(u8, items[start..], '/') orelse return fileError.IndiceError;
        end = start + pos;
        try indices.append(try std.fmt.parseInt(u32, items[start..end], 10)-1);

        triangleCount+=1;
        buffer.clearRetainingCapacity(); // Clear buffer
    }
    const Indices: []u32 = try allocator.alloc(u32, triangleCount*3);
    errdefer allocator.free(Indices);
    std.mem.copyForwards(u32, Indices, indices.items);
    
    // ===== determine face normals =====
    // ----- Find face normals -----
    const faceNormals = try allocator.alloc(zmath.Vec3, triangleCount);
    errdefer allocator.free(faceNormals);
    defer allocator.free(faceNormals);

    i = 0;
    while(i<triangleCount):(i+=1){
        const a: u32 = Indices[i*3];
        const b: u32 = Indices[i*3+1];
        const c: u32 = Indices[i*3+2];
        
        const v1:zmath.Vec3 = zmath.Vec3{.x = Vertices[a*5], .y = Vertices[a*5+1], .z = Vertices[a*5+2]};
        const v2:zmath.Vec3 = zmath.Vec3{.x = Vertices[b*5], .y = Vertices[b*5+1], .z = Vertices[b*5+2]};
        const v3:zmath.Vec3 = zmath.Vec3{.x = Vertices[c*5], .y = Vertices[c*5+1], .z = Vertices[c*5+2]};

        faceNormals[i] = v2.subtract(v1).cross(v3.subtract(v1));
    }

    // ----- Find vertice normals -----
    const normals = try allocator.alloc(f32, 3*vertexCount);
    errdefer allocator.free(normals);
    defer allocator.free(normals);
    
    i=0;
    while(i<triangleCount):(i+=1){
        const faceNormal = faceNormals[i]; // Find normal of face
        
        for (Indices[i*3..i*3+2]) | Iv | {
            // Add normal to vertex-normals
            normals[Iv*3] += faceNormal.x;
            normals[Iv*3+1] += faceNormal.y;
            normals[Iv*3+2] += faceNormal.z;
        }
    }

    // ----- Normalize vertex normals -----
    i=0;
    while(i<vertexCount):(i+=1) {
        math.vec3normalize(normals[i*3..i*3+3]);
    }

    // ===== Construct and return mesh =====
    return try resourceManager.createMesh("MapMesh", Vertices, Indices, normals);
}

pub fn importObjRobust (resourceManager: *zune.graphics.ResourceManager, obj_file: []const u8) !void {
    // ===== Initialize variables =====
    // Take allocator from resourceManager
    const allocator = resourceManager.allocator;
    
    // find file
    const file = try std.fs.cwd().openFile(obj_file, .{});

    // Create buffered reader -> Stores sections of file in buffer to minimize calls to system
    var buffered = std.io.bufferedReader(file.reader());

    // Create buffer to store lines
    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    // Skip non-vertex lines
    while(buffered.buf[buffered.start] != ' '){ // loop through v's until 'v '
        try readUntil(&buffered, 'v'); // Skip until first vector 
    }
    try moveStart(&buffered, -1);

    // ===== Read vertices =====
    var vertices: [40]f32 = file;
    try storeLineInfo(f32, &buffered, &buffer, vertices[0..], "v ");
    for (vertices, 0..) | vertex, i | std.debug.print("vertices[{}]: {d}\n", .{i, vertex});

}

pub fn storeLineInfo(comptime T: type, bufferedReader: anytype, buffer: *std.ArrayList(u8), array: []T, linePreceder: []const u8) !void {
    const convertFun = switch (@typeInfo(T)){
        .int => std.fmt.parseInt,
        .comptime_int => std.fmt.parseInt,
        .float => std.fmt.parseFloat,
        .comptime_float => std.fmt.parseFloat,
        else => return fileError.InvalidDataType
    };

    // ----- Read until line preceder is found -----
    var precederFound = false;
    while(!precederFound){
        try readUntil(bufferedReader, linePreceder[0]);
        precederFound = true;

        // If line-preceder is multi-character check all characters
        if (linePreceder.len > 1){
            for (linePreceder[1..]) | char | {
                if (bufferedReader.buf[bufferedReader.start] == char) {
                    try increaseStart(bufferedReader);
                } else{ // If character is unexpected
                    precederFound = false;
                }
            }
        }
    } 

    // ===== Start loading in data =====
    var array_i:usize = 0; // Stores index of next empty space in 'array'
    var lineLen = try readUntilDelimiter(bufferedReader, buffer.writer(), '\n', false);
    var inLineBlock = true; // Reader is inside block of lines with 'linePreceder'
    while(inLineBlock){
        // ----- Prepare reading of line -----
        var bufStart: usize = 0;

        // ----- convert data in line -----
        const items = buffer.items;
        while (std.mem.indexOfScalar(u8, items[bufStart..lineLen], ' ')) | valueLen |{ // Assume values are seperated by ' '
            // Read value out of buffer
            array[array_i] = try convertFun(T, items[bufStart..bufStart+valueLen]);
            array_i+=1;

            // Go to next value in buffer
            bufStart+= valueLen+1; // Skip ' '
        }
        // Load last line
        array[array_i] = try convertFun(T, items[bufStart..lineLen]);
        array_i+=1;

        // ----- Load in new line -----
        buffer.clearRetainingCapacity();
        if (!try checkPreceder(bufferedReader, linePreceder)){ // check if next line starts with linePreceder
            inLineBlock = false; // if not exit
            break;
        }
        lineLen = try readUntilDelimiter(bufferedReader, buffer.writer(), '\n', false); // Store line Length of next line
    }

}
/// Check if first character(s) in buffer are the same as preceder
/// Buffer moves over checked memory. 
fn checkPreceder(buffered:anytype, preceder: []const u8) !bool {
    // ===== Single character compare =====
    if (preceder.len == 1) {
        const result:bool = buffered.buf[buffered.start] == preceder[0];
        try increaseStart(buffered); // skip preceder
        return result;
    }
    
    // ===== Multi-character compare =====
    const precederEnd = buffered.start + preceder.len;
    if (precederEnd <= buffered.end){ // if preceder should fall within buffer
        const result = std.mem.eql(u8, preceder, buffered.buf[buffered.start..precederEnd]);
        if (precederEnd == buffered.end) { // if buffer is completely read
            try refreshBuffer(buffered); // refresh buffer
        } else{
            buffered.start += preceder.len;
        }
        return result;
    } else{ // preceder is split between current buffer and next to-be-loaded buffer
        const overlap: usize = buffered.start-buffered.end;
        
        // ----- compare section 1 -----
        var precederFound: bool = true; 
        precederFound = precederFound and std.mem.eql(u8, preceder[0..overlap], buffered.buf[buffered.start..buffered.end]);
        
        // ----- load next buffer -----
        try refreshBuffer(buffered);
        
        // ----- compare section 2 -----
        precederFound = precederFound and std.mem.eql(u8, preceder[overlap..], buffered.buf[0..preceder.len-overlap]);

        // ----- increment buffer.start -----
        buffered.start += preceder.len-overlap; // Skip preceder
        
        return precederFound;
    }
}

fn increaseStart(buffered:anytype) !void {
    if (buffered.start+1 == buffered.end){ // Increasing would go outside of buffer length
        // Reload buffered reader with new data
        try refreshBuffer(buffered);
    } else {
        buffered.start += 1;
    }
}

fn refreshBuffer(buffered: anytype) !void {
    const n:usize = try buffered.unbuffered_reader.read(buffered.buf[0..]);
    if (n == 0) return fileError.EndOfStream; // Buffer could not be refilled

    buffered.start = 0;
    buffered.end = n;
}

pub fn readUntilDelimiter(buffered: anytype, writer: anytype, delimiter: u8, p: bool) !usize {
    var len:usize = 0;
    while (true) {
        const start = buffered.start;
        if (std.mem.indexOfScalar(u8, buffered.buf[start..buffered.end], delimiter)) | pos | {
            if (pos == 0) {
                len += writer.context.items.len; // Edge-case -> first item is delimiter -> return length of existing buffer
                buffered.start += 1;
                return len;
            }
            if (p) {
                std.debug.print("pos: {}\n", .{pos});
                std.debug.print("buffered.buf: {s}|\n", .{buffered.buf[start..start+pos-1]});
            }
            len += pos; // update read-length
            
            // found delimiter
            try writer.writeAll(buffered.buf[start..start+pos]); // Write all till before delimiter

            buffered.start += pos+1; // Set start after delimiter position
            return len-1;
        } else {
            if (p) std.debug.print("wrapped\n", .{});
            // No delimiter found -> write all
            try writer.writeAll(buffered.buf[start..buffered.end]);

            len += buffered.end-start;

            // refill buffer
            const n:usize = try buffered.unbuffered_reader.read(buffered.buf[0..]);
            if (n == 0) return fileError.EndOfStream; // Buffer could not be refilled

            buffered.start = 0;
            buffered.end = n;
        }
    }
}

/// progresses buffered until after certain delimiter
pub fn readUntil(buffered: anytype, delimiter: u8) !void {
    while (true) {
        const start = buffered.start;
        if (std.mem.indexOfScalar(u8, buffered.buf[start..buffered.end], delimiter)) | pos | {
            // found delimiter
            buffered.start += pos+1; // Set start after delimiter position
            return;
        } else {
            // No delimiter found
            // refill buffer
            const n:usize = try buffered.unbuffered_reader.read(buffered.buf[0..]);
            if (n == 0) return fileError.EndOfStream; // Buffer could not be refilled
            buffered.start = 0;
            buffered.end = n;
        }
    }
}

pub fn moveStart(buffered:anytype, movement: isize) !void {
    if (movement < 0) { 
        if (buffered.start<-movement) {return fileError.InvalidReaderMovement;}  // Too far back
            else {buffered.start -= @as(usize, @intCast(-movement));}}
    else  {
        if (buffered.end-buffered.start<=movement) {return fileError.InvalidReaderMovement;}  // Too far forward
            else {buffered.start += @as(usize, @intCast(movement));}
    }
}

// /// Find first line with desired value after 'skipLines' skipped lines at start of document 
// pub fn readLineOf(buffered: anytype, delimiter: u8, skipLines: usize) {
//     var len:usize = 0;
//     while (true) {
//         const start = buffered.start;
//         if (std.mem.indexOfScalar(u8, buffered.buf[start..buffered.end], delimiter)) | pos | {
//             len += buffered.end-start; // update read-length
            
//             // found delimiter
//             try writer.writeAll(buffered.buf[start..start+pos]); // Write all till before delimiter

//             buffered.start += pos+1; // Set start after delimiter position
//             return len;
//         } else {
//             // No delimiter found -> write all
//             try writer.writeAll(buffered.buf[start..buffered.end]);

//             len += buffered.end-start;

//             // refill buffer
//             const n:usize = try buffered.unbuffered_reader.read(buffered.buf[0..]);
//             if (n == 0) return fileError.EndOfStream; // Buffer could not be refilled

//             buffered.start = 0;
//             buffered.end = n;
//         }
//     }
// }