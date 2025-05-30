const std = @import("std");
const math = @import("../math.zig");
const util_print = @import("../utils/prints.zig");

const Allocator: type = std.mem.Allocator;

const HalfMatLen = 10;
const ErrorMatrix = [HalfMatLen]f64; // row major generally (last 2 indices unused)
const avec3 = @Vector(3, f32);

const PlaceHolderMesh = @import("processing.zig").PlaceHolderMesh;

const indexOfPtr = @import("processing.zig").indexOfPtr;

// =====================================
//             FUNCTIONS
// =====================================

pub fn collapseMesh(mesh: *PlaceHolderMesh, err_threshold: f32) !void {

    // ===== Create halfEdge mesh =====
    std.debug.print("create halfEdges\n", .{});
    var halfEdges = try HalfEdges.fromPHMesh(mesh);
    defer halfEdges.deinit();
    std.debug.print("Created halfedges\n", .{});
    try halfEdges.collapseMesh(err_threshold);
}

fn indices_manifoldCheck(allocator: Allocator, indices: []u32) !void {
    const faceCount = @divExact(indices.len, 3);

    var hashMap = std.AutoHashMap([2]u32, u8).init(allocator);

    var i: usize = 0;
    while (i < faceCount) : (i += 1) { // face
        for (0..3) |j| { // edges in face
            const v_root: u32 = indices[@intCast(i * 3 + j)];
            const v_end: u32 = indices[@intCast(i * 3 + @rem(j + 1, 3))];

            const edge_vertices: [2]u32 = if (v_root < v_end) [2]u32{ v_root, v_end } else [2]u32{ v_end, v_root };

            const hm_results = try hashMap.getOrPut(edge_vertices);
            if (!hm_results.found_existing) {
                hm_results.value_ptr.* = 1;
            } else {
                hm_results.value_ptr.* += 1;
                if (hm_results.value_ptr.* < 2) return error.Unexpected;
            }
        }
    }

    var border_edges: usize = 0;

    var value_iterator = hashMap.valueIterator();
    while (value_iterator.next()) |value_ptr| {
        if (value_ptr.* > 2) {
            return LinkedErrorsErrors.ManifoldEdge;
        }
        if (value_ptr.* == 1) {
            border_edges += 1;
        }
    }

    if (border_edges > 0) {
        std.debug.print("\n {} border edges found in mesh with {} faces\n\n", .{ border_edges, faceCount });

        std.debug.print("keys:\n", .{});
        var hm_iter = hashMap.iterator();
        var kv = hm_iter.next();
        while (kv != null) {
            if (kv.?.value_ptr.* == 1) {
                // const borderFace:u32 = @divFloor(kv.?.key_ptr[0], 3);
                // const faceIndices = indices[borderFace*3..][0..3];
                std.debug.print("{}-{}\n", .{ kv.?.key_ptr[0], kv.?.key_ptr[1] });
                // std.debug.print("Example border-face[{}]: ({}, {}, {})\n", .{borderFace, faceIndices[0], faceIndices[1], faceIndices[2]});
            }

            kv = hm_iter.next();
        }
    }
}

// =====================================
//               STRUCTS
// =====================================

const HalfEdgeError = error{ TooManyNeighbours, NotEnoughNeighbours, NoQuadricErrors, NoEdgeErrors, FaceFlip, DetachedVertex, SingularFace };

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

    /// Removes duplicates from `mesh`. This will invalidate texCoords and normals.
    pub fn fromPHMesh(mesh: *PlaceHolderMesh) !HalfEdges {
        // ===== Retrieve required info =====
        const allocator = mesh.allocator;
        const triangleCount = mesh.triangleCount;
        const indices = mesh.indices;
        const vertices = mesh.vertices;

        // std.debug.print("Checking manifold-ness before creating half edges...\n", .{});
        // try indices_manifoldCheck(allocator, indices);

        // ===== De-duplicate mesh vertices =====
        try mesh.removeDuplicateVertices();

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

                // // ===== DEBUG CODE =====

                // if(triangleCount == 992){
                //     // const ofset0 = @divFloor(currInd, 3);
                //     // const ofset1 = @divFloor(nextInd, 3);
                //     // const ofset2 = @divFloor(prevInd, 3);

                //     // if(!(ofset0 == ofset1 and ofset0 == ofset2 and ofset1 == ofset2)) return error.Unexpected; // indices are not part of the same face

                //     // if(i == 0){
                //     //     if(j == 2){
                //     //         std.debug.print("Checking manifold-ness before ", .{});
                //     //         try indices_manifoldCheck(allocator, indices);

                //     //         std.debug.print("indices[0..3]: ({}, {}, {})\n", .{indices[0], indices[1], indices[2]});
                //     //         const o1 = halfEdges[halfEdges[currInd].next].origin; // 0
                //     //         const o2 = halfEdges[halfEdges[currInd].prev].origin; // 1
                //     //         const o3 = halfEdges[currInd].origin; // 2
                //     //         // const o4 = halfEdges[halfEdges[j].prev].origin; // 1

                //     //         std.debug.print("origins face[{}]: ({}, {}, {})\n", .{i, o1, o2, o3});
                //     //     }
                //     // }
                // }

                // // ===== DEBUG CODE =====

                if (links.fetchPutAssumeCapacity(linkNext, currInd)) |twin| {

                    // // ===== DEBUG CODE =====
                    // if(twin.value >= halfEdges.len) {
                    //     twinless[currInd] = false;

                    //     const v: u32 = twin.value - @as(u32,@intCast(halfEdges.len)); // 5
                    //     std.debug.print("\nTriple edge[{}] between: {}-{}\n", .{currInd, linkNext[0], linkNext[1]});
                    //     std.debug.print("triple-edge face[{?}]: {}, {}, {}\n", .{halfEdges[currInd].i_face, indices[currInd], indices[nextInd], indices[prevInd]});
                    //     const face1_0 = halfEdges[v].origin; // 5
                    //     const face1_1 = halfEdges[halfEdges[v].next].origin; // 3
                    //     const face1_2 = halfEdges[halfEdges[v].prev].origin; // 4
                    //     std.debug.print("\nindices[3..6]: ({}, {}, {})\n", .{indices[3], indices[4], indices[5]});
                    //     std.debug.print("original edge[{}] face1[{?}]: {}, {}, {}\n", .{v, halfEdges[v].i_face, face1_1, face1_2, face1_0});

                    //     const t = halfEdges[v].twin; // 2
                    //     const face2_0 = halfEdges[t].origin; // 2
                    //     const face2_1 = halfEdges[halfEdges[t].next].origin; // 0
                    //     const face2_2 = halfEdges[halfEdges[t].prev].origin; // 1
                    //     std.debug.print("\nindices[0..3]: ({}, {}, {})\n", .{indices[0], indices[1], indices[2]});
                    //     std.debug.print("original egde[{}] face2[{?}]: {}, {}, {}\n", .{t, halfEdges[t].i_face, face2_1, face2_2, face2_0});

                    //     // std.debug.print("\nface2[1]/face2[2].next.next: {}/{}\n\n\n", .{face2_2, halfEdges[halfEdges[halfEdges[t].next].next].origin});

                    //     continue;
                    // }

                    // // ===== DEBUG CODE =====

                    // ----- Fill in twin fields for both -----
                    const twinInd = twin.value;

                    halfEdges[currInd].twin = twinInd;
                    halfEdges[twinInd].twin = currInd;

                    twinless[currInd] = false;
                    twinless[twinInd] = false;

                    const value = links.getPtr(twin.key).?;
                    value.* = @intCast(halfEdges.len + value.*);

                    twinnedCount += 2;
                }
            }
        }
        // std.debug.print("linksCount/triangleCount*3: {}/{}\n", .{links.count(), triangleCount*3});
        // for (halfEdges, 0..) | he, ind | std.debug.print("[{}]: {any}\n", .{ind, he});
        // ===== Create border twins =====
        const HE_start: u32 = @intCast(halfEdges.len);
        // std.debug.print("HE_start: {}\n", .{HE_start});
        const edgeCount: u32 = HE_start + (HE_start - twinnedCount); // total + (edges - edges with twins) = total + twinless edges
        const halfEdges_ext: []HalfEdge = try allocator.realloc(halfEdges, edgeCount);
        // const border_ext: []bool = try allocator.realloc(border, edgeCount);

        var j: u32 = 0;
        for (twinless, 0..) |b, n| {
            if (!b) continue; // skip if has twin

            // // ===== DEBUG PRINT =====
            // var noTwin:bool = true;
            // for(halfEdges_ext[0..HE_start]) | edge | {
            //     if(edge.twin == n) {
            //         noTwin = false;
            //         break;
            //     }
            // }
            // if(noTwin){
            //     std.debug.print("Twinless edge has no twin\n", .{});
            // } else {
            //     std.debug.print("Twinless edge has twin\n", .{});
            // }

            // var vertex_mentioned = try allocator.alloc(bool, @divExact(vertices.len,3));
            // for(0..vertex_mentioned.len) | m | vertex_mentioned[m] = false;
            // for(halfEdges) | edge | {
            //     vertex_mentioned[edge.origin] = true;
            // }
            // var uniqueVertices:u32 = 0;
            // for(vertex_mentioned) | m | {
            //     if(m) uniqueVertices +=1;
            // }
            // std.debug.print("Unique vertices: {}\n", .{uniqueVertices});

            // // var doubleEdges:u32 = 0;
            // // var links_value_iterator = links.valueIterator();
            // // while(links_value_iterator.next()) | value | {
            // //     if(value.* == @divExact(vertices.len, 3)) std.debug.print("Triple allocated edge\n", .{});
            // // }

            // std.debug.print("edgeCount: {}\n", .{edgeCount});
            // std.debug.print("edge[{}] is twinless\n", .{n});
            // const vertex_root = halfEdges_ext[n].origin;
            // const vertex_end = halfEdges_ext[halfEdges_ext[n].next].origin;
            // std.debug.print("edge[{}]: {}-{}\n", .{n, vertex_root, vertex_end});
            // std.debug.print("vertex[{}]: ", .{vertex_root});
            // printVector(vertices[vertex_root*3..][0..3].*);
            // std.debug.print("vertex[{}]: ", .{vertex_end});
            // printVector(vertices[vertex_end*3..][0..3].*);
            // std.debug.print("\n", .{});

            // // ===== DEBUG PRINT =====

            const pos: u32 = @intCast(n);
            // std.debug.print("pos: {}\n", .{pos});

            // ----- next HalfEdge element in original -----
            const nextHE: HalfEdge = halfEdges_ext[halfEdges_ext[pos].next];

            // ----- determine if next element of border exists -----
            var i_leadingInnerBorder = halfEdges_ext[pos].prev; // counter clockwise over root until next twinless edge is found (or faceless edge i.e. complete border)
            while (!twinless[i_leadingInnerBorder]) { // if leadingInnerBorder is twinless i.e. is an edge of the mesh
                if (halfEdges_ext[halfEdges_ext[i_leadingInnerBorder].twin].i_face == null) break; // If outer border is encountered -> Border exists
                i_leadingInnerBorder = halfEdges_ext[halfEdges_ext[i_leadingInnerBorder].twin].prev; // Move to next potential inner border
            }
            const nextBorderExists = !twinless[i_leadingInnerBorder];

            // ----- determine if previous element of border exists -----
            var i_nextInnerBorder = halfEdges_ext[pos].next; // counter clockwise over root until next twinless edge is found (or faceless edge i.e. complete border)
            while (!twinless[i_nextInnerBorder]) { // if nextBorderTwin_pos is edgeless
                if (halfEdges_ext[halfEdges_ext[i_nextInnerBorder].twin].i_face == null) break; // If outer border is encountered -> Border exists
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
                .next = if (nextBorderExists) halfEdges_ext[i_leadingInnerBorder].twin else undefined,
                .prev = if (prevBorderExists) halfEdges_ext[i_nextInnerBorder].twin else undefined, // Previous border should be found out
                .i_face = null,
            };
            halfEdges_ext[pos].twin = i_new;
            twinless[pos] = false;

            if (nextBorderExists) halfEdges_ext[halfEdges_ext[i_leadingInnerBorder].twin].prev = i_new;
            if (prevBorderExists) halfEdges_ext[halfEdges_ext[i_nextInnerBorder].twin].next = i_new;

            j += 1;
        }

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
        const allocator = self.allocator;

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
        if (self.quadricError == null) try self.addErrorMatrices(1000);

        if (self.edgeErrors == null) try self.addEdgeErrorsList();
        const edgeErrors = self.edgeErrors.?;

        // // ===== DEBUG PRINT =====
        // if(self.indices.len < 300) {
        //     for(self.HE, 0..) | edge, i | {
        //         const root = edge.origin;
        //         const tip = self.HE[edge.next].origin;
        //         const origin_pair: [2]u32 = if(root<tip) [2]u32{root, tip} else [2]u32{tip, root};
        //         std.debug.print("edge[{}] {}-{} collapses to: ", .{i, origin_pair[0], origin_pair[1]});
        //         util_print.printVector(f32, self.edgeErrors.?[i].newPos);
        //     }
        //     self.print();

        //     for(0..@divExact(self.faceNormals.len, 3)) | i | {
        //         const norm = self.faceNormals[i*3..][0..3].*;
        //         std.debug.print("normal[{:<3}]: ", .{i});
        //         util_print.printVector(f32, norm);
        //     }

        //     const qe1 = self.quadricError.?[5];
        //     const t1:[16]f64 = .{
        //     qe1[0], qe1[1], qe1[2], qe1[3],
        //     qe1[1], qe1[4], qe1[5], qe1[6],
        //     qe1[2], qe1[5], qe1[7], qe1[8],
        //     qe1[3], qe1[6], qe1[8], qe1[9]};

        //     const qe2 = self.quadricError.?[6];
        //     const t2:[16]f64 = .{
        //     qe2[0], qe2[1], qe2[2], qe2[3],
        //     qe2[1], qe2[4], qe2[5], qe2[6],
        //     qe2[2], qe2[5], qe2[7], qe2[8],
        //     qe2[3], qe2[6], qe2[8], qe2[9]};

        //     std.debug.print("\nquadric error of vertex 5 before collapse:\n", .{});
        //     util_print.print_CM_4Matd(t1);

        //     std.debug.print("\nquadric error of vertex 6 before collapse:\n", .{});
        //     util_print.print_CM_4Matd(t2);
        // }
        // // ===== DEBUG PRINT =====

        // printEdgeHeader();
        // for([_]usize{2268, 2271, 3893, 2279, 2277, 2280, 2281, 2282, 2275, 2276, 2269, 2270, 2265, 2266, 2267, 2262, 2263, 3890, 3888, 3889, 3894, 2256, 2259, 2261, 2260, 2284, 2285, 2280, 2281, 2282, 2277}) |edge| self.printEdge(edge);

        // ===== Create linkedErrors list =====
        std.debug.print("Start collapse with error threshold: {d}\n", .{errThreshold});
        var LE = try LinkedErrors.fromEdgeErrors(allocator, edgeErrors, errThreshold);
        defer LE.deinit();

        var debug: u32 = 0;
        var onlyErrors: bool = false;
        while (!onlyErrors) : (LE.resetStart()) {
            onlyErrors = true;
            var chainExists = true;

            // ===== DEBUG PRINT =====
            std.debug.print("looping\n", .{});
            // ===== DEBUG PRINT =====

            while (LE.getEdgeIndexWithLowestError()) |edge| {
                self.edge = edge;
                var EndOfChain = false;
                // ===== DEBUG PRINT ======
                std.debug.print("\nprocessed edge: {}\n", .{edge});

                if (edge == 4314) {
                    self.printEdgeChain(19050, LE);
                    std.debug.print("\n", .{});
                }

                if (self.HE[19050].prev == self.HE[19050].next) {
                    std.debug.print("degenerate mesh\n", .{});
                    self.printEdgeChain(19050, LE);
                    std.debug.print("\n", .{});
                    return error.Unexpected;
                }

                if (self.edge == 1176) {
                    printEdgeHeader();
                    self.printEdge(19050);
                    self.printEdge(19086);
                }

                if (self.edge == 1776) {
                    printEdgeHeader();
                    self.printEdge(19050);
                    self.printEdge(19086);
                }

                if (self.edge == 2523) {
                    std.debug.print("error of edge[{}] ({}): {}/{}\n", .{ edge, LE.inChain(edge), LE.edgeErrors[edge].err, errThreshold });
                    // printEdgeHeader();
                    // for([_]u32{16, 15, 17, 58})|e|self.printEdge(e);
                    // std.debug.print("\n", .{});
                    // std.debug.print("\nedge[16]:", .{});
                    // for([_]u32{64, 51, 49, 16, 60, 33, 16}) | e | std.debug.print("edge[{}] inChain: {}\n", .{e, LE.inChain(e)});
                }
                // ===== DEBUG PRINT ======
                // std.debug.print("\nprocessed edge: {}\n", .{edge});
                // std.debug.print("error of edge[{}] ({}): {}/{}\n", .{ edge, LE.inChain(edge), LE.edgeErrors[edge].err, errThreshold });
                // if(self.edgeErrors.?[edge].err >= errThreshold) return error.Unexpected;

                // ===== Collapse edge =====
                // if(!LE.inChain(2271)) return error.Unexpected;
                // try LE.chainCheck(self.HE); // Check chain integrity

                // std.debug.print("\n---------------------------------------------\n", .{});
                // std.debug.print("collapsing edge({}): {}\n", .{ debug, self.edge });

                self.collapseEdge() catch |err| switch (err) {
                    HalfEdgeError.FaceFlip, HalfEdgeError.DetachedVertex, HalfEdgeError.NotEnoughNeighbours, HalfEdgeError.TooManyNeighbours, HalfEdgeError.SingularFace => {
                        // std.debug.print("collapse failed: {}\n\n", .{e});
                        LE.moveStartUp() catch |move_err| switch (move_err) { // Move start up as current edge cannot be collapsed
                            LinkedErrorsErrors.EndOfChain => { // If edge_start cannot be moved up
                                break; // Break to reset the chain
                            },
                            else => return move_err,
                        };
                        continue;
                    },
                    else => return err,
                };
                onlyErrors = false; // something collapsed while iterating over edges

                // ===== Propegate edge collapse in linkedErrors =====
                // ----- re-order halfEdges -----
                if (self.edge == 2523) {
                    std.debug.print("flag0\n", .{});
                    printEdgeHeader();
                    self.printEdgeWithOrigin(self.getHalfEdge().origin);
                    std.debug.print("halfedge count: {}\n", .{self.HE.len});
                    for (self.alteredErrorsBuffer.items) |alt| {
                        std.debug.print("altered edge: {}\n", .{alt.index});
                    }
                }

                if (edge == 4314) {
                    std.debug.print("altered edges:\n", .{});
                    printEdgeHeader();
                    for (self.alteredErrorsBuffer.items) |alt| {
                        self.printEdge(alt.index);
                    }
                }

                try LE.reevaluateEntries(self.alteredErrorsBuffer.items); // remove try -> remove try from LLspot
                if (self.edge == 2523) std.debug.print("flag1\n", .{});

                // ----- remove deleted edges ------
                const removeEdge1 = self.edge;
                const removeEdge2 = self.getHalfEdge().twin;

                LE.removeFaceOfEdge(removeEdge1, self.HE) catch |err| switch (err) {
                    LinkedErrorsErrors.EndOfChain => { // LE.linkStart has reached end of chain -> Try to reset
                        EndOfChain = true;
                    },
                    LinkedErrorsErrors.EmptyChain => {
                        // std.debug.print("removeFace1: returned emptyChain\n", .{});
                        chainExists = false; // No more edges in chain link
                    },
                    LinkedErrorsErrors.AllItemsExceedError => {
                        // std.debug.print("removeFace1: returned AllItemsExceedError\n", .{});
                        chainExists = false; // No more collapsable edges
                    },
                    else => return err, // Unexpected error
                };
                if (self.edge == 2523) std.debug.print("flag2\n", .{});
                LE.removeFaceOfEdge(removeEdge2, self.HE) catch |err| switch (err) {
                    LinkedErrorsErrors.EndOfChain => { // LE.linkStart has reached end of chain -> Try to reset
                        EndOfChain = true;
                    },
                    LinkedErrorsErrors.EmptyChain => {
                        // std.debug.print("removeFace2: returned emptyChain\n", .{});
                        chainExists = false; // No more edges in chain link
                    },
                    LinkedErrorsErrors.AllItemsExceedError => {
                        self.printEdgeChain(removeEdge2, LE);
                        // std.debug.print("removeFace2: returned AllItemsExceedError\n", .{});
                        chainExists = false; // No more collapsable edges
                    },
                    else => return err, // Unexpected error
                };
                if (self.edge == 2523) std.debug.print("flag3\n", .{});

                debug += 1;

                // // ===== DEBUG =====
                // chainExists = false;
                // // ===== DEBUG =====

                if (EndOfChain or !chainExists) {
                    // std.debug.print("Exit loop via EndOfChain({}) or !chainExists({})\n", .{EndOfChain, !chainExists});
                    break; // end of chain has been reached by start -> reset start
                }
            }

            // if(LE.getEdgeIndexWithLowestError() == null and chainExists) std.debug.print("Exit loop due to error threshold being exceeded in all edges\n", .{});

            if (!chainExists) break; // If all edges in linkedErrors have collapsed
        }

        // try LE.chainCheck(self.HE);

        // ===== Alter placeholder mesh according to LinkedErrors =====
        std.debug.print("Alter PHMesh:\n", .{});

        // ===== DEBUG PRINT =====
        // {
        //     LE.printChainItems(100);
        //     const qe1 = self.quadricError.?[5];
        //     const t1:[16]f64 = .{
        //     qe1[0], qe1[1], qe1[2], qe1[3],
        //     qe1[1], qe1[4], qe1[5], qe1[6],
        //     qe1[2], qe1[5], qe1[7], qe1[8],
        //     qe1[3], qe1[6], qe1[8], qe1[9]};

        //     const qe2 = self.quadricError.?[6];
        //     const t2:[16]f64 = .{
        //     qe2[0], qe2[1], qe2[2], qe2[3],
        //     qe2[1], qe2[4], qe2[5], qe2[6],
        //     qe2[2], qe2[5], qe2[7], qe2[8],
        //     qe2[3], qe2[6], qe2[8], qe2[9]};

        //     std.debug.print("\nquadric error of vertex 5 after collapse:\n", .{});
        //     util_print.print_CM_4Matd(t1);

        //     std.debug.print("\nquadric error of vertex 6 after collapse:\n", .{});
        //     util_print.print_CM_4Matd(t2);
        // }
        // ===== DEBUG PRINT =====
        try LE.updateToPHMesh(self.HE, self.mesh);
    }

    /// Modify self to collapse edge, stores alteredEdgeErrInfo in `self.alteredErrorsBuffer`
    pub fn collapseEdge(self: *HalfEdges) !void {
        // // ===== DEBUG PRINT =====
        // if(new_pos_[0] == 0 and new_pos_[1] == 0 and new_pos_[2] == 0){
        // {
        //     const new_pos = self.edgeErrors.?[self.edge].newPos;
        //     std.debug.print("Collapsing edge[{}] to \n", .{self.edge});
        //     util_print.printVector(f32, new_pos);

        //     const root = self.HE[self.edge].origin;
        //     const tip = self.HE[self.HE[self.edge].next].origin;
        //     const pair: [2]u32 = if(root<tip) .{root, tip} else .{tip, root};
        //     std.debug.print("collapsing edge[{}]: {}-{}\n", .{self.edge, pair[0], pair[1]});
        //     std.debug.print("{}: ", .{pair[0]});
        //     util_print.printVector(f32, self.vertices[pair[0]*3..][0..3].*);

        //     std.debug.print("{}: ", .{pair[1]});
        //     util_print.printVector(f32, self.vertices[pair[1]*3..][0..3].*);
        // }
        // // ===== DEBUG PRINT =====
        const currEdge = self.edge;
        const edgeBase = &self.HE[0];

        // ===== Check needed field =====
        if (self.quadricError == null) return HalfEdgeError.NoQuadricErrors;
        if (self.edgeErrors == null) return HalfEdgeError.NoEdgeErrors;

        // ===== Check collapsed-face is not singular =====
        for (0..2) |_| {
            const new_pos = self.edgeErrors.?[self.edge].newPos;

            const oposing_origin = self.HE[self.getHalfEdge().prev].origin;
            const oposing_vertex = self.vertices[oposing_origin * 3 ..][0..3];
            if (new_pos[0] == oposing_vertex[0] and new_pos[1] == oposing_vertex[1] and new_pos[2] == oposing_vertex[2]) {
                return HalfEdgeError.SingularFace;
            }
            self.flip();
        }

        // ===== Fetch mutual neighbours in buffers =====
        const commonNeighbourTuple = try self.fetchCommonNeighbours();
        const onBound = commonNeighbourTuple.onBoundary;
        const twinEdges = commonNeighbourTuple.edgesFromMSV;

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

        for (bufferWithRemovedOrigin.items) |item| { // Change larger origin index to smaller origin index
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
        // if (onBound) return error.Unexpected;
        // std.debug.print("Modifying indices(1)...\n", .{});
        self.modifyIndices(&self.normalBuffer1, &self.indexBuffer1, mergedOrigin, removedOrigin) catch |err| {
            // std.debug.print("Restoring collapse(1)...\n", .{});
            self.edge = currEdge;
            @memcpy(self.vertices[mergedOrigin * 3 ..][0..3], &V_mergedOrigin_old);
            try self.restoreCollapse(onBound, null, removedOrigin, true, false);
            return err;
        };

        self.flip();
        // std.debug.print("Modifying indices(2)...\n", .{});
        self.modifyIndices(&self.normalBuffer2, &self.indexBuffer2, mergedOrigin, removedOrigin) catch |err| {
            self.edge = currEdge;
            @memcpy(self.vertices[mergedOrigin * 3 ..][0..3], &V_mergedOrigin_old); // Restore vertex position
            try self.restoreCollapse(onBound, null, removedOrigin, true, true); // restore the rest
            return err;
        };

        // ===== Alter twins =====
        // std.debug.print("Altering twins...\n", .{});
        // - Store original twin values for restoration
        // - Check if outside-twins have a face -> If not, mutual neighbouring face (MNF) will collapse to single line

        const collapsingFaces: [2]u32 = .{ self.HE[self.edge].i_face orelse std.math.maxInt(u32), self.HE[self.HE[self.edge].twin].i_face orelse std.math.maxInt(u32) }; // neighbouring faces of collapsing edge
        var twinInfos: [2]CollapsingFaceTwins = .{ undefined, undefined };
        // std.debug.print("{any}\n", .{twinEdges});
        var i: usize = 0;
        while (i < twinEdges.len) : (i += 1) {
            // for (twinEdges[0..], 0..) | *twinEdge, i| {
            const twinEdge = twinEdges[i];
            if (onBound and i == 1) { // for boundary edge -> only 1 neighbouring face -> Store the prev-/next-boundary instead
                // If boundary is 2+ edges -> collapse face as normal:
                // - Store twin pairs in twinInfos
                // - Match outer edges to each other
                // - Remove inner edges from linked list
                // If boundary is 3+ edges -> shorten boundary.
                // ----- Determine boundary edge -----
                const boundaryEdge = if (self.HE[currEdge].i_face == null) currEdge else self.getHalfEdge().twin;

                // ----- Store boundary values -----
                const i_prev = self.HE[boundaryEdge].prev;
                const i_next = self.HE[boundaryEdge].next;

                // // ----- Check for void validity -----
                // if (self.HE[i_prev].prev == i_next) { // if chain length is 3 (triangle)

                // }

                twinInfos[i].inner1 = i_prev;
                twinInfos[i].outer1 = i_next;

                self.HE[i_prev].next = i_next;
                self.HE[i_next].prev = i_prev;

                continue;
            }

            // TODO: SEE EFFECTS OF ONBOUNDARY -> CAN WE JUST SET ONBOUND AS FALSE & ARE VOIDS THEN HANDLED CORRECTLY FOR TRIANGLE VOIDS

            // ----- for edges check if they are on MNF -----
            if (twinEdge[0].i_face orelse std.math.maxInt(u32) == collapsingFaces[0] or twinEdge[0].i_face == collapsingFaces[1]) { // first twinEdge is on MNF -> Second edge is outside of MNF

                // ----- Store original edge pairs -----
                twinInfos[i] = .{
                    .outer1 = twinEdge[0].twin,
                    .inner1 = @intCast(indexOfPtr(HalfEdge, edgeBase, twinEdge[0])),
                    .inner2 = twinEdge[1].twin,
                    .outer2 = @intCast(indexOfPtr(HalfEdge, edgeBase, twinEdge[1])),
                };
            } else { // second twinEdge is inside shared face
                // ----- Store original edge pairs -----
                twinInfos[i] = .{
                    .outer1 = @intCast(indexOfPtr(HalfEdge, edgeBase, twinEdge[0])),
                    .inner1 = twinEdge[0].twin,
                    .inner2 = @intCast(indexOfPtr(HalfEdge, edgeBase, twinEdge[1])),
                    .outer2 = twinEdge[1].twin,
                };
            }

            // ----- make edges outside of MNF 'skip' MNF -----
            // // ===== DEBUG PRINT =====
            // if (currEdge == 60) {
            //     if (i == 0) std.debug.print("onBoundary: {}\n", .{onBound});
            //     std.debug.print("\ntwinInfos[{0}].inner1 = {1}\ntwinInfos[{0}].outer1 = {2}\ntwinInfos[{0}].inner2 = {3}\ntwinInfos[{0}].outer2 = {4}\n", .{ i, twinInfos[i].inner1, twinInfos[i].outer1, twinInfos[i].inner2, twinInfos[i].outer2 });
            // }
            // // ===== DEBUG PRINT =====
            const i_out1 = twinInfos[i].outer1; // Index of edges outside of shared face
            const i_out2 = twinInfos[i].outer2;
            self.HE[i_out1].twin = i_out2;
            self.HE[i_out2].twin = i_out1;
        }

        // ===== Verify if MSF are still valid =====
        // Condition for validity is that shared faces should adjoint at least 1 additional face
        for (twinInfos) |tInfo| {
            if (self.HE[tInfo.outer1].i_face == null and self.HE[tInfo.outer2].i_face == null) {
                self.edge = currEdge;
                @memcpy(self.vertices[mergedOrigin * 3 ..][0..3], &V_mergedOrigin_old);
                try self.restoreCollapse(onBound, twinInfos, removedOrigin, true, true);
                return HalfEdgeError.DetachedVertex; // Vertex has single connecting edge but no neighbouring faces
            }
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
        for ([2][]*HalfEdge{ self.buffer1.items, self.buffer2.items }) |inwardsEdges| {
            for (inwardsEdges) |edge| {
                // ----- set self.edge to to-be-altered edge -----
                self.edge = @intCast(indexOfPtr(HalfEdge, edgeBase, edge));

                // ----- check if edge is on collapsing face -----
                const edgeFace = self.getHalfEdge().i_face;
                const removedEdge = (edgeFace == collapsingFaces[0] or edgeFace == collapsingFaces[1]); // edge is on collapsing face
                const doNotCheckTwin = switch (onBound) {
                    false => self.onTwinInfoOuters(twinInfos[0]) or self.onTwinInfoOuters(twinInfos[1]), // results in double check between buffer1 (vertex at root of self.edge) and buffer 2 (vertex at end of self.edge)
                    true => self.onTwinInfoOuters(twinInfos[0]),
                };

                if (!removedEdge) { // if edge is not on collapsing face
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

                if (doNotCheckTwin or removedTwinEdge) continue; // if edge is on collapsing face or causes double update -> do not try to alter

                // std.debug.print("update edge {}\n", .{self.edge});
                try self.alteredErrorsBuffer.append(AlteredEdgeErrorInfo{
                    .index = self.edge,
                    .edgeErrorInfo = try self.getEdgeError(),
                });
            }
        }

        self.edge = currEdge;
    }

    /// Checks if edge is on outer
    fn onTwinInfoOuters(self: HalfEdges, twinInfo: CollapsingFaceTwins) bool {
        if (self.edge == twinInfo.outer1 or self.edge == twinInfo.outer2) return true;
        return false;
    }

    /// Sets `self.edgeErrors`. Same ordering as `self.HE`
    pub fn addEdgeErrorsList(self: *HalfEdges) !void {
        const allocator = self.allocator;
        const edgeCount = self.HE.len;
        const currEdge = self.edge;

        const edgeErrors = try allocator.alloc(EdgeErrInfo, edgeCount);

        var i: u32 = 0;
        while (i < edgeCount) : (i += 1) {
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

        // // ===== DEBUG PRINT =====
        // // {
        //     const pair: [2]u32 = if(root<tip) [2]u32{root, tip} else [2]u32{tip, root};
        //     std.debug.print("getEdgeError of {}-{}\n", .{pair[0], pair[1]});
        // // }
        // // ===== DEBUG PRINT =====
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
        const t: [16]f64 = .{ m[0], m[1], m[2], qe1[3] + qe2[3], m[4], m[5], m[6], qe1[6] + qe2[6], m[8], m[9], m[10], qe1[8] + qe2[8], m[12], m[13], m[14], qe1[9] + qe2[9] };

        // var M:[16]f64 = undefined;
        // math.eigen_mat4d_robust_inverse(&m, &M);

        // var v_optimal: [4]f64 = M[12..16].*;

        // ===== Determine center of edge =====
        const vertices = self.vertices;
        const root = self.getHalfEdge().origin;
        const tip = self.HE[self.getHalfEdge().next].origin;
        const v0: [3]f64 = .{ @as(f64, @floatCast(vertices[root * 3] + vertices[tip * 3])) / 2, @as(f64, @floatCast(vertices[root * 3 + 1] + vertices[tip * 3 + 1])) / 2, @as(f64, @floatCast(vertices[root * 3 + 2] + vertices[tip * 3 + 2])) / 2 };

        // ===== eigen biased-solution =====
        var v_optimal: [4]f64 = undefined;
        _ = math.eigen_optimal_vertex(&t, &v0, 0.001, &v_optimal);
        // std.debug.print("solved: {}\n", .{solved});
        // ===== eigen biased-solution =====

        // // ===== DEBUG PRINT =====
        // {
        //     if(v_optimal[0] < -0.1 or v_optimal[1] < -0.1 or v_optimal[2] < -0.1){
        //         std.debug.print("v_optimal is inverse: ", .{});
        //         util_print.printVector(f64, v_optimal[0..3].*);
        //         std.debug.print("v0: ", .{});
        //         util_print.printVector(f64, v0);

        //         // std.debug.print("Error matrix:\n", .{});
        //         // util_print.print_CM_4Matd(m);

        //     } else {
        //         std.debug.print("v_optimal is correct\n", .{});
        //     }

        //     if(self.edge == 27){
        //         std.debug.print("qe[5]\n", .{});
        //     }
        //     // if self.edge()
        //     // util_print(qe1)
        // }
        // // ===== DEBUG PRINT =====

        var rowVector: [4]f64 = undefined;
        math.eigen_vec4d_multiply(&t, &v_optimal, &rowVector);

        const err_value: f64 = rowVector[0] * v_optimal[0] + rowVector[1] * v_optimal[1] + rowVector[2] * v_optimal[2] + rowVector[3] * v_optimal[3];
        if (@abs(err_value) < 5 * std.math.pow(f32, 10, -6)) { // Precision error -> round to full values
            return .{ .err = 0, .newPos = .{ @floatCast(v_optimal[0]), @floatCast(v_optimal[1]), @floatCast(v_optimal[2]) } };
        }

        if (err_value < 0) {
            return .{ .err = 0, .newPos = .{ @floatCast(v_optimal[0]), @floatCast(v_optimal[1]), @floatCast(v_optimal[2]) } };
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

        return .{ .err = @floatCast(err_value), .newPos = .{ @floatCast(v_optimal[0]), @floatCast(v_optimal[1]), @floatCast(v_optimal[2]) } };
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
        if (twinInfos) |twinInfo| {
            const edges = self.HE;
            for (twinInfo, 0..) |twins, i| {
                if (onBoundary and i == 1) { // if onboundary -> Only 1 neighbouring face i.e. 1 set of twins -> Restore boundary ordering instead
                    // Hopefully this works: untested
                    const boundaryEdge = if (self.getHalfEdge().i_face == null) self.edge else self.getHalfEdge().twin;
                    edges[twins.inner1].next = boundaryEdge;
                    edges[twins.outer1].prev = boundaryEdge;
                    continue;
                }

                edges[twins.inner1].twin = twins.outer1;
                edges[twins.outer1].twin = twins.inner1;
                edges[twins.inner2].twin = twins.outer2;
                edges[twins.outer2].twin = twins.inner2;
            }
        }

        if (has_changed_indices_1 or has_changed_indices_2) {
            if (removedOrigin == null) return error.InvalidDataType; // removeOrigin is required value

            const smaller = self.HE[self.edge].origin < self.HE[self.HE[self.edge].twin].origin;
            const replacedOriginEdgeBuffer = if (smaller) self.buffer2 else self.buffer1;
            for (replacedOriginEdgeBuffer.items) |item| {
                self.HE[item.twin].origin = removedOrigin.?;
            }
            const collapsedEdge = if (smaller) self.HE[self.edge].twin else self.edge;
            self.HE[collapsedEdge].origin = removedOrigin.?;
        }

        if (has_changed_indices_1) {
            if (removedOrigin == null) return error.InvalidDataType; // removeOrigin is required value

            const normals = self.faceNormals;
            const indices = self.indices;

            for (self.normalBuffer1.items) |normalInfo| {
                @memcpy(normals[normalInfo.i_face..][0..3], &normalInfo.normal);
            }
            for (self.indexBuffer1.items) |ind| {
                indices[ind] = removedOrigin.?;
            }
        }

        if (has_changed_indices_2) {
            if (removedOrigin == null) return error.InvalidDataType;

            const normals = self.faceNormals;
            const indices = self.indices;

            for (self.normalBuffer2.items) |normalInfo| {
                @memcpy(normals[normalInfo.i_face..][0..3], &normalInfo.normal);
            }
            for (self.indexBuffer2.items) |ind| {
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
            const norm_old = faceNormals[i_currFace..][0..3];

            const currIndices = indices[i_currFace..][0..3];
            if (std.mem.indexOfScalar(u32, currIndices, removedVertex)) |pos| {
                // std.debug.print("face: {} != {}/{}\n", .{i_currFace, leftFace, rightFace});
                // std.debug.print("RemovedVertex: {}\n", .{removedVertex});
                // std.debug.print("currIndices: {any}\n", .{currIndices});
                // std.debug.print("indiceChange in edge indices[{}]: {} -> {}\n", .{i_currFace+pos, currIndices[pos], mergedVertex});
                currIndices[pos] = mergedVertex; // May make invalid face for collapsing faces due to collapsing edge origin and end becoming the same origin
                try replacedIndicesBuffer.append(i_currFace + @as(u32, @intCast(pos)));
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
    /// Special case for 3-long edges of null-space: treat null-space as valid mesh and return as null-edges as second edge-pair.
    ///
    /// Sets `self.buffer1` to store all HalfEdges pointing to vertex at base of `self.edge`. Similarly `self.buffer2` stores all HalfEdges pointing to vertex at end of `self.edge`.
    /// Both exclude `self.edge` and its twin.
    pub fn fetchCommonNeighbours(self: *HalfEdges) !struct { edgesFromMSV: [2][2]*HalfEdge, onBoundary: bool } {
        const currEdge = self.edge;

        // if(currEdge == 2264 or currEdge == 2261 or currEdge == 2265 or currEdge == 2267) std.debug.print("collapsing edge: {}\n", .{currEdge});

        // std.debug.print("Fetching Neighbours...\n", .{});
        const boundary1 = self.HE[self.edge].i_face == null;
        try self.fetchNeighbours(&self.buffer1, true);
        self.flip();
        const boundary2 = self.HE[self.edge].i_face == null;
        try self.fetchNeighbours(&self.buffer2, true);
        self.edge = currEdge; // revert to original edge position

        const onBound = boundary1 or boundary2; // edge only aligned to 1 face
        // std.debug.print("onBound: {}\n", .{onBound});

        var twinEdge1: [2]*HalfEdge = undefined; // Store halfedges from common neighbouring vertex to start and end of collapsing edge
        var twinEdge2: [2]*HalfEdge = undefined;

        // ===== Store mutual neighbours =====
        var n_count: u32 = 0; // shared neighbours count
        const n_desired: u32 = switch (onBound) {
            true => 1,
            false => 2,
        };

        // for (self.buffer2.items, 0..)|item2, k| std.debug.print("self.buffer2.items[{}]: {}\n", .{k, item2.origin});
        for (self.buffer1.items) |item| {
            // std.debug.print("buf1.item.origin: {}\n", .{item.origin});
            if (getIndexOfVertex(self.buffer2.items, item.origin)) |pos| { // check for item of buffer 1 of the vertex is also found in buffer2
                // std.debug.print("flag0\n", .{});
                switch (n_count) {
                    0 => {
                        twinEdge1 = .{ item, self.buffer2.items[pos] };
                        if (onBound) { // TODO: REMOVE THIS CODE TO BREAK OUT -> IMPLIES INHERRENT TRUST THAT ONLY 1 NEIGHBOUR MAY BE FOUND i.e. n_count WILL ALWAYS BE EQUAL TO n_desired
                            n_count += 1;
                            break; // if on boundary -> only 1 face
                        }
                    },
                    1 => twinEdge2 = .{ item, self.buffer2.items[pos] },
                    else => return HalfEdgeError.TooManyNeighbours,
                }
                n_count += 1;
            }
        }
        if (n_count < n_desired) {
            // std.debug.print("buffer1:\n{any}\n", .{self.buffer1.items});
            // std.debug.print("buffer2:\n{any}\n", .{self.buffer2.items});
            // std.debug.print("n_count: {}\n", .{n_count});
            return HalfEdgeError.NotEnoughNeighbours;
        }

        // const twinEdges: [2][2]*HalfEdge = switch (onBound) {
        //     true => tmp: {
        //         const boundaryEdge = if (boundary1) self.edge else self.getHalfEdge().twin; // if boundary1 == true -> currEdge.face == null else boundary2 == true -> currEdge.twin.face == null
        //         if(self.HE[boundaryEdge].next == self.HE[self.HE[boundaryEdge].prev].prev){ // Special case -> void is triangle -> handle same as normal face
        //             twinEdge2[0] = self.HE[boundaryEdge].prev;
        //             twinEdge2[1] = self.HE[self.HE[boundaryEdge].next].twin;
        //         }
        //         break :tmp
        //         .{ [2]*HalfEdge{ twinEdge1[0], twinEdge1[1] }, [2]*HalfEdge{ twinEdge2[0], twinEdge2[1] } };
        //         }, // on bound
        //     false => .{ [2]*HalfEdge{ twinEdge1[0], twinEdge1[1] }, [2]*HalfEdge{ twinEdge2[0], twinEdge2[1] } },
        // };

        const boundaryEdge = if (boundary1) self.edge else self.getHalfEdge().twin; // if boundary1 == true -> currEdge.face == null else boundary2 == true -> currEdge.twin.face == null
        if (self.HE[boundaryEdge].next == self.HE[self.HE[boundaryEdge].prev].prev) { // Special case -> void is triangle -> handle same as normal face
            twinEdge2[0] = self.HE[boundaryEdge].prev;
            twinEdge2[1] = self.HE[self.HE[boundaryEdge].next].twin;
        }
        const twinEdges: [2][2]*HalfEdge = .{ [2]*HalfEdge{ twinEdge1[0], twinEdge1[1] }, [2]*HalfEdge{ twinEdge2[0], twinEdge2[1] } };

        return .{ .edgesFromMSV = twinEdges, .onBoundary = onBound };
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

        if (exclude_first and p) std.debug.print("buf[-1]: {}/{} {?}\n", .{ self.edge, self.HE.len, self.getHalfEdge().i_face });
        // if (exclude_first and p) if (self)
        if (exclude_first) self.rotEndCCW(); // skip first edge
        if (p) std.debug.print("buf[0]: {}\n", .{self.edge});
        // if(p) self.printEdge(self.edge);

        buffer.appendAssumeCapacity(self.getHalfEdge()); // first neighbour
        self.rotEndCCW(); // Next edge pointing to vertex at root of currEdge
        if (p) std.debug.print("buf[1]: {}\n", .{self.edge});
        // if(p) self.printEdge(self.edge);

        buffer.appendAssumeCapacity(self.getHalfEdge()); // second neighbour

        // ----- Find remaining neighbours -----
        var debug: u32 = 1;
        while (buffer.getLast() != buffer.items[0]) { // not looped back yet
            // std.debug.print("{}|", .{buffer.getLast().origin});
            debug += 1;
            if (p and debug > 10) return error.Unexpected;
            self.rotEndCCW(); // next edge
            if (p) std.debug.print("buf[{}]: {}\n", .{ debug, self.edge });
            // if(p) self.printEdge(self.edge);
            const he = self.getHalfEdge();
            try buffer.append(he);
        }
        if (p) std.debug.print("\n", .{});

        _ = buffer.pop(); // remove duplicate
        if (exclude_first) _ = buffer.pop(); // exclude self.edge <- second to last edge in list

        // ===== Restore self =====
        self.edge = currEdge;
    }

    /// Returns index of halfedge in array with origin `vertex`
    fn getIndexOfVertex(array: []*HalfEdge, vertex: u32) ?u32 {
        const bufferSize = array.len;
        var i: u32 = 0;
        // while(i<array.len):(i+=1){
        //     if(array[i].origin == vertex) return i;
        // }
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

        for (halfEdges) |he| {
            if (he.i_face == null) { // If edge is on a boundary -> alter vertices to have penalty away from boundary
                // Get edge information
                const boundaryHE = halfEdges[he.twin];
                const F = boundaryHE.i_face.?;

                const i_1 = boundaryHE.origin;
                const i_2 = halfEdges[boundaryHE.next].origin;

                const V_1 = vertices[i_1 * 3 ..][0..3];
                const V_2 = vertices[i_2 * 3 ..][0..3];

                const V_edge: [3]f32 = .{ V_2[0] - V_1[0], V_2[1] - V_1[1], V_2[2] - V_1[2] };
                const V_normal = normals[F..][0..3].*;

                const V_norm_boundary = math.vec3Cross(V_edge, V_normal);
                const a = V_norm_boundary[0];
                const b = V_norm_boundary[1];
                const c = V_norm_boundary[2];
                const d = -(a * V_1[0] + b * V_1[1] + c * V_1[2]);

                const errBoundMat: ErrorMatrix = .{ a * a * penalty, a * b * penalty, a * c * penalty, a * d * penalty, b * b * penalty, b * c * penalty, b * d * penalty, c * c * penalty, c * d * penalty, d * d * penalty };

                for ([2]u32{ i_1, i_2 }) |i| {
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
        for (self.HE, 0..) |he, edge| {
            if (he.origin == origin) {
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
        std.debug.print("{d:<10} | {d:<10} | {d:<10} | {d:<10} | {d:<10} | {?:<10} |\n", .{ edge_ind, origin, twin, next_, prev, face });
    }

    fn printFace(V1: [3]f32, V2: [3]f32, V3: [3]f32) void {
        std.debug.print("({d:<9.5}, {d:<9.5}, {d:<9.5}), ({d:<9.5}, {d:<9.5}, {d:<9.5}), ({d:<9.5}, {d:<9.5}, {d:<9.5})\n", .{ V1[0], V1[1], V1[2], V2[0], V2[1], V2[2], V3[0], V3[1], V3[2] });
    }

    fn printVector(v: [3]f32) void {
        std.debug.print("({d:<9.5}, {d:<9.5}, {d:<9.5})\n", .{ v[0], v[1], v[2] });
    }

    fn errInfoCompare(_: void, e1: EdgeErrInfo, e2: EdgeErrInfo) bool {
        return e1.err < e2.err;
    }

    pub fn printEdgeChain(self: HalfEdges, edge: u32, linkedList: LinkedErrors) void {
        var i = edge;
        std.debug.print("edge[{}] ({})->", .{ i, linkedList.inChain(i) });
        i = self.HE[i].next;
        while (i != edge) : (i = self.HE[i].next) {
            std.debug.print("edge[{}] ({})->", .{ i, linkedList.inChain(i) });
        }
        std.debug.print("edge[{}] ({})->", .{ i, linkedList.inChain(i) });
    }

    pub fn print(self: HalfEdges) void {
        const vertexCount = @divExact(self.vertices.len, 3);
        const triangleCount = @divExact(self.indices.len, 3);

        std.debug.print("------ Vertices ------\n", .{});
        for (0..vertexCount) |i| {
            std.debug.print("{:<3}: ", .{i});
            util_print.printVector(f32, self.vertices[i * 3 ..][0..3].*);
        }

        std.debug.print("------ Indices ------\n", .{});
        for (0..triangleCount) |i| {
            std.debug.print("{:<3}: ", .{i});
            util_print.printVector(u32, self.indices[i * 3 ..][0..3].*);
        }
    }
};

const LinkedErrorsErrors = error{
    ItemNotFound,
    EndOfChain,
    StartOfChain,
    EmptyChain,
    InvalidFlagRemoval,
    AllItemsExceedError,
    ManifoldEdge,
};

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
        var i: u32 = 0;
        while (i < itemCount) : (i += 1) {
            linkedList[i].value = edgeErrors[i].err;
        }

        // connect 'linkedList' to be sorted & retreive sorted indices of edgeErrors 'surrogateLinks'
        const surrogateLinks = try linkUpToAscendingValues(allocator, linkedList);
        defer allocator.free(surrogateLinks);
        const linkStart = surrogateLinks[0].originalIndex;
        const linkEnd = surrogateLinks[itemCount - 1].originalIndex; // Last item in linked list

        // ===== Create value-flags (linkedList-order) =====
        const validEdgeCount = std.sort.lowerBound(SurrogateLink, surrogateLinks, errorCutOff, cutOffCompare); // return index of first edge above cutOff value
        const flagCount: usize = if (validEdgeCount > 0) @max(@divTrunc(validEdgeCount, @as(usize, @intFromFloat(@round(@sqrt(@as(f32, @floatFromInt(validEdgeCount))))))), 1) else 1; // return sqrt(n) flags | enforce O(sqrt(n))?

        var valueFlags = try std.ArrayList(FlagItem).initCapacity(allocator, flagCount);

        // ----- keep track of which LinkedItem is flagged -----
        const flagged = try allocator.alloc(?u16, itemCount); // flagged[edge] = index in self.valueFlags
        for (0..itemCount) |j| flagged[j] = null;

        // ----- populate value flags -----
        const flagSpacing: u16 = @intCast(@divFloor(validEdgeCount, flagCount));
        var j: u16 = 0; // flag-index
        while (j < flagCount) : (j += 1) {
            const index = surrogateLinks[j * flagSpacing].originalIndex; // index of flag-position in linkedList

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

        var i: u32 = 0;
        while (i < itemCount) : (i += 1) {
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
        linkedList[surrogates[itemCount - 1].originalIndex].i_next = itemCount;
        linkedList[surrogates[itemCount - 1].originalIndex].i_prev = surrogates[itemCount - 2].originalIndex;

        i = 1;
        while (i < itemCount - 1) : (i += 1) {
            const i_prev = surrogates[i - 1].originalIndex;
            const i_next = surrogates[i + 1].originalIndex;
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
        while (LL[i].i_prev != LLLen) {
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

        // ===== Set linkItem/edgeError values | remove items from linkedList =====
        const linkedList = self.linkedList;
        const edgeErrors = self.edgeErrors;

        var EmptyChain = false;
        var EndOfChain = false;
        var AllItemsExceedError = false;

        var i: u32 = 0;
        while (i < alteredCount) : (i += 1) {
            const edgeIndex = alteredErrors[i].index;
            edgeErrors[edgeIndex] = alteredErrors[i].edgeErrorInfo;
            linkedList[edgeIndex].value = alteredErrors[i].edgeErrorInfo.err;

            self.removeItemCareful(alteredErrors[i].index) catch |err| switch (err) {
                LinkedErrorsErrors.EndOfChain => EndOfChain = true,
                LinkedErrorsErrors.EmptyChain => EmptyChain = true,
                LinkedErrorsErrors.AllItemsExceedError => AllItemsExceedError = true,
                else => return err,
            };
        }

        // ===== Remove altered values from linkedList =====
        // NOTE: Needs linkedList.values to be set for flag moving

        // i = 0;
        // std.debug.print("edge[781] exists before removal: {}\n", .{self.inChain(781)});
        // while(i<alteredCount):(i+=1) {
        //     if(alteredErrors[i].index == 774) std.debug.print("Removing edge[{}] for re-sorting\n", .{alteredErrors[i].index});
        //     // std.debug.print("Removing edge: {d:<10}\n", .{alteredErrors[i].index});

        // }
        // std.debug.print("edge[781] exists after removal: {}\n", .{self.inChain(781)});

        // ===== Insert altered data =====
        const flags = self.valueFlags.items;
        const cutOffError = self.errorCutOff;
        // const LLLen: u32 = @intCast(linkedList.len);

        i = 0;
        var i_flag: usize = 0;
        var i_insert: u32 = 0;
        while (i < alteredCount) : (i += 1) {
            // std.debug.print("edge[781] exists at start of loop({}): {}\n", .{i, self.inChain(781)});
            // if(i==0) std.debug.print("inserting item[{}]\n", .{alteredErrors[i].index});
            const alteredErr = alteredErrors[i].edgeErrorInfo.err; // new edge error
            const alteredInd = alteredErrors[i].index; // halfEdge index

            // ----- check if chain exists -----
            if (EmptyChain) {
                // std.debug.print("Seeding chain\n", .{});
                try self.seedChain(alteredInd);
                EndOfChain = false;
                EmptyChain = false;
                continue;
            }

            // if(alteredInd == 774) std.debug.print("Inserting Edge[774]...\n", .{});
            // ----- check if item has valid error -----
            if (alteredErr > cutOffError) { // if halfEdge error is too large -> attach to end of chain
                // if(alteredInd == 774 and i == 0) {
                //     self.printChain(100);
                //     // std.debug.print("errorTooLarge\n", .{});
                //     // std.debug.print("self.linkEnd: {}\nself.linkStart: {}\nfirstFlagInd:{}\n", .{self.linkEnd, self.linkStart, self.valueFlags.items[0].index});
                //     // std.debug.print("edge[781] exists before insertion: {}\n", .{self.inChain(781)});
                // }

                if (EndOfChain) {
                    if (self.linkEnd == self.linkStart) {
                        self.linkStart = alteredInd; // new item is attached to end -> move start their
                        EndOfChain = false; // insert causes self.linkStart to not be last item anymore
                    }
                }

                self.insertItem(alteredInd, self.linkEnd);
                // if(alteredInd == 774 and i == 0) std.debug.print("edge[781] exists after insertion: {}\n", .{self.inChain(781)});

                continue;
            }

            // ----- check if item should be inserted before start -----
            if (alteredErr < self.valueFlags.items[0].err) { // Only applies to first altered item really
                if (alteredInd == 774 and i == 0) std.debug.print("smallestError\n", .{});

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
            i_insert = if (flag_ind_found != 0)
                try self.findLLSpot(alteredErr, flags[i_flag].index)
            else
                try self.findLLSpot(alteredErr, i_insert); // if in same flag section -> Use previous found index to start search

            self.insertItem(alteredInd, i_insert);

            // ===== Handle potential errors =====
            if (EndOfChain and i_insert == self.linkEnd) { // If linkStart reached end of chain, but chain expands -> move to expanded item
                self.linkStart = alteredInd;
                EndOfChain = false;
            }
        }

        if (EmptyChain) return LinkedErrorsErrors.EmptyChain;
        if (EndOfChain) return LinkedErrorsErrors.EndOfChain;
        if (AllItemsExceedError) {
            // self.printChainItems(10);
            // if(self.inChain(781)) std.debug.print("edge[781] is in chain with error: {d}\n", .{self.edgeErrors[781].err}) else std.debug.print("edge[781] not in the chain", .{});
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
        if (i_insert == self.linkEnd) {
            // std.debug.print("Moved self.linkEnd\n", .{});
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

        if (i_insert == i_chainStart) {
            try self.moveFlagDown(0);
        }
        if (i_insert == i_start) {
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
        for (self.valueFlags.items) |flagItem| {
            self.flagged[flagItem.index] = null;
        }
        self.valueFlags.clearRetainingCapacity();

        // ===== Create value-flag =====
        try self.valueFlags.append(.{ .err = self.linkedList[i_linkedItem].value, .index = i_linkedItem });
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
        const d = false;
        if (d) std.debug.print("removing face of {}\n", .{edgeIndex});
        var i: u32 = edgeIndex;

        var EndOfChain: bool = false;
        var EmptyChain: bool = false;
        var AllItemsExceedError: bool = false;

        if (d) std.debug.print("removing edge {}\n", .{i});
        self.removeItemCareful(i) catch |err| switch (err) {
            LinkedErrorsErrors.EndOfChain => EndOfChain = true,
            LinkedErrorsErrors.EmptyChain => EmptyChain = true,
            LinkedErrorsErrors.AllItemsExceedError => AllItemsExceedError = true,
            else => return err,
        };

        if (halfEdges[edgeIndex].i_face != null) { // if original edge is adjacent to defined face
            i = halfEdges[i].next;
            while (i != edgeIndex) : (i = halfEdges[i].next) {
                if (d) std.debug.print("removing edge {}\n", .{i});
                self.removeItemCareful(i) catch |err| switch (err) {
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
    /// - AllItemsExceedError, lowest error-item still exceeds error threshold, item was deleted first -> self.chainStart is moved to next (un-ordered) item
    /// - Misc error, unexpected
    pub fn removeItemCareful(self: *LinkedErrors, edgeIndex: u32) !void {
        if (self.linkStart == edgeIndex) self.moveStartUp() catch |err| switch (err) { // if linkStart is in danger of being displaced of the chain -> move up-chain
            LinkedErrorsErrors.EndOfChain => {
                // std.debug.print("Start did not move up\n", .{});
                try self.removeItem(edgeIndex);
                return err;
            },
            else => return err,
        };
        if (self.linkEnd == edgeIndex) self.moveEndDown() catch |err| switch (err) { // if linkEnd is in danger of being displaced of the chain -> move end down
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
        if (flagged[edgeIndex]) |_| {
            // if(edgeIndex == 774) std.debug.print("moving flag[{?}]\n", .{flagged[edgeIndex]});
            // self.printChainItems(10);
            self.moveFlag(edgeIndex) catch |err| switch (err) {
                LinkedErrorsErrors.AllItemsExceedError => { // Continue removal and pass error
                    const item = &LL[edgeIndex];

                    if (item.i_prev < LL.len) LL[item.i_prev].i_next = item.i_next; // if valid item index -> link index to point around itself
                    if (item.i_next < LL.len) LL[item.i_next].i_prev = item.i_prev;
                    return err;
                },
                else => return err,
            };

            // std.debug.print("new flag[0].index: {}\n", .{self.valueFlags.items[0].index});
            // self.printChainItems(10);
        }

        const item = &LL[edgeIndex];

        if (item.i_prev < LL.len) LL[item.i_prev].i_next = item.i_next; // if valid item index -> link index to point around itself
        if (item.i_next < LL.len) LL[item.i_next].i_prev = item.i_prev;
    }

    /// Find index in linkedList for which all next items have a larger error.
    ///
    /// If linkedList does not contain a larger index return last item
    ///
    /// If index is at very start of chain, return `self.linkedList.len`
    fn findLLSpot(self: LinkedErrors, err: f32, startIndex: usize) !u32 {
        const linkedList = self.linkedList;
        const itemCount = linkedList.len;

        var i: usize = startIndex;
        // var debug:usize = 0;
        while (true) {
            // if(debug>500) return error.Unexpected else debug+=1;
            // std.debug.print("{}|", .{i});
            const linkedItem = linkedList[i];
            if (linkedItem.i_next == itemCount) {
                // std.debug.print("^", .{});
                return @intCast(i); // If i_next is invalid -> end of links -> use last valid index
            }
            if (linkedItem.value > err) {
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
        const prevFlag = if (i_flag == 0) null else &flags[i_flag - 1];
        const nextFlag = if (i_flag + 1 >= flagCount) null else &flags[i_flag + 1];

        // ----- Go over edge case -----
        if (prevFlag == null) {
            try self.moveFlagUp(i_flag); // If first flag -> Can only move up
            return;
        }

        // ----- determine size of prior/curr flag region -----
        const LL = self.linkedList;

        var prevSize: u16 = 0;

        var i: u32 = prevFlag.?.index;
        while (i != currFlag.index) {
            prevSize += 1;
            i = LL[i].i_next;
        }

        var currSize: u16 = 0;
        i = currFlag.index;
        if (nextFlag == null) { // go till error
            const cutOff = self.errorCutOff;
            if (LL[self.linkEnd].value < cutOff) {
                while (i != self.linkEnd) : (i = LL[i].i_next) {
                    currSize += 1;
                }
            } else {
                while (LL[i].value < cutOff) : (i = LL[i].i_next) {
                    currSize += 1;
                }
            }
        } else { // go till next flag
            while (i != nextFlag.?.index) : (i = LL[i].i_next) {
                currSize += 1;
            }
        }

        // ----- check if flag should be removed -----
        if (prevSize + currSize < flagCount) {
            // std.debug.print("flag0\n", .{});
            try self.removeFlag(i_flag);
            return;
        }

        if (prevSize > currSize) {
            // std.debug.print("flag1\n", .{});
            try self.moveFlagDown(i_flag);
        } else {
            // std.debug.print("flag2\n", .{});
            try self.moveFlagUp(i_flag);
        }
    }

    /// Removes flag
    fn removeFlag(self: *LinkedErrors, i_flag: u16) !void {
        if (i_flag == 0) {
            // self.printChain(2000);
            return LinkedErrorsErrors.InvalidFlagRemoval;
        }

        // std.debug.print("Removing flag[{}] on edge {d:<10}\n", .{i_flag, self.valueFlags.items[i_flag].index});

        const flagged = self.flagged;
        const flags = self.valueFlags.items;
        const flagCount = flags.len;

        const flaggedEdge = flags[i_flag].index;
        flagged[flaggedEdge] = null;
        // std.debug.print("flagged[{}]: {?}\n", .{flaggedEdge, flagged[flaggedEdge]});

        var i: u16 = i_flag + 1; // change flagged pointers of all subsequent flags
        while (i < flagCount) : (i += 1) {
            flagged[flags[i].index] = i - 1; // move flag pointers in flagged to prior flag
        }
        _ = self.valueFlags.orderedRemove(i_flag); // remove i_flag

    }

    /// Move flag up by 1. May invalidate pointers to self.valueFlags
    ///
    /// Special cases:
    /// - Next index already has a flag                         -> replace flag
    /// - Flag is on last item of `self.linkedList`             -> remove flag
    /// - Flag moves to an item with too large an error         -> remove flag
    /// - First flag moves to an item with too large an error   -> move flag to next item, return AllItemsExceedError
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
            if (i_flag != 0) {
                try self.removeFlag(i_flag);
                return;
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
            const nextFlagInd = if (i_flag != flagCount - 1) flags[i_flag + 1].index else return; // index in LL of next flag | if last flag item -> No overlapping
            if (newFlagIndex == nextFlagInd) { // if flag overlaps with next flag index
                // std.debug.print("Flags [{}] & [{}] overlap -> Remove flag[{}]\n", .{i_flag, i_flag + 1, i_flag + 1});
                try self.removeFlag(i_flag + 1); // remove next flag
                flagged[newFlagIndex] = i_flag; // removeFlag will remove flagged[prev_flag] which is now overlapping -> rewrite it
            }
        } else { // If flag points to unreachable chain item -> Remove flag
            _ = self.valueFlags.orderedRemove(i_flag);
        }

        if (i_flag == 0 and flag.err > self.errorCutOff) {
            // self.printChainItems(40);
            return LinkedErrorsErrors.AllItemsExceedError;
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
        if (i_flag == 0) return LinkedErrorsErrors.InvalidFlagRemoval;
        if (LL[flaggedEdge].i_prev == LL.len) return LinkedErrorsErrors.StartOfChain;

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
        const prevFlagInd = flags[i_flag - 1].index; // index in LL of next flag
        if (newFlagIndex == prevFlagInd) { // if flag overlaps with previous flag index
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
        const LL_length: u32 = @intCast(LL.len);

        // ===== Store face-adjacent halfEdges =====
        const longEdges: []HalfEdge = try allocator.alloc(HalfEdge, LL.len);

        var i: u32 = self.valueFlags.items[0].index;
        var j: u32 = 0; // Count of face-adjacent edges
        while (i < LL_length) : (i = LL[i].i_next) {
            if (halfEdges[i].i_face != null) { // go through chain and store edges which have a valid face
                longEdges[j] = halfEdges[i];
                j += 1;
            }
        }

        // // ===== DEBUG PRINT =====
        // {
        // var faceCounter: [18]u8 = .{0} ** 18;
        // i = self.valueFlags.items[0].index;
        // std.debug.print("\nedges in chain:\n", .{});
        // std.debug.print("Edge       | Origin     | Twin       | Next       | Prev       | i_face     |\n", .{});
        // while(i<LL_length):(i = LL[i].i_next){
        //     const edge = halfEdges[i];
        //     const edge_ind = i;
        //     const origin = edge.origin;
        //     const twin = edge.twin;
        //     const next_ = edge.next;
        //     const prev = edge.prev;
        //     const face = edge.i_face;
        //     std.debug.print("{d:<10} | {d:<10} | {d:<10} | {d:<10} | {d:<10} | {?:<10} |\n", .{edge_ind, origin, twin, next_, prev, face});
        //     if(face!=null)faceCounter[@divExact(face.?, 3)] +=1;
        // }

        // for(faceCounter, 0..) |count, k | {
        //     std.debug.print("face[{}]: {}\n", .{k, count});
        // }
        // }
        // std.debug.print("j: {}\n", .{j});
        // // ===== DEBUG PRINT =====

        const faceCount = @divExact(j, 3);

        const edges: []HalfEdge = try allocator.realloc(longEdges, j); // trim longedges to valid edges
        defer allocator.free(edges);

        // // ===== DEBUG PRINT =====
        // var bordering_edges: u32 = 0;
        // var outside_edges: u32 = 0;
        // // const twinCount = try allocator.alloc(u8, halfEdges.len);
        // for (edges) | edge| {
        //     if(halfEdges[edge.twin].i_face == null){ // if edge was inside edge to border
        //         bordering_edges+=1;
        //     }
        //     if(edge.i_face == null){
        //         outside_edges+=1;
        //     }
        // }
        // std.debug.print("Edges bordering no-face: {}\n", .{bordering_edges});
        // std.debug.print("un-filtered border-edges: {}\n", .{outside_edges});

        // var originPairs = std.AutoHashMap([2]u32, u8).init(allocator);
        // try originPairs.ensureTotalCapacity(@intCast(@divFloor(edges.len, 2)));
        // defer originPairs.deinit();

        // for(edges) | edge | {
        //     const root_vertex = edge.origin;
        //     const end_vertex = halfEdges[edge.next].origin;
        //     const vertexPair: [2]u32 = if(root_vertex<end_vertex) .{root_vertex, end_vertex} else .{end_vertex, root_vertex};

        //     const result = originPairs.getOrPutAssumeCapacity(vertexPair);

        //     if(result.found_existing){
        //         result.value_ptr.* += 1;
        //     }else{
        //         result.value_ptr.* = 1;
        //     }
        // }

        // var pairs_values = originPairs.valueIterator();
        // var m:usize = 0;
        // while(pairs_values.next()) | pair_value | {
        //     m+=1;
        //     if(!(pair_value.* == 0 or pair_value.* == 2)){
        //         std.debug.print("Origins found with singular edge\n", .{});
        //     }
        // }
        // std.debug.print("originPairs item count: [{}]\n", .{m});

        // try he_manifoldCheck(allocator, edges, halfEdges);
        // // ===== DEBUG PRINT =====

        // ===== Find used indices/vertices =====
        const intactVertex: []bool = try allocator.alloc(bool, mesh.vertexCount);
        const intactFace: []bool = try allocator.alloc(bool, mesh.triangleCount);
        defer allocator.free(intactVertex);
        defer allocator.free(intactFace);

        // ----- initialize to false -----
        const minIntactLen = @min(intactFace.len, intactVertex.len);
        i = 0;
        while (i < minIntactLen) : (i += 1) {
            intactVertex[i] = false;
            intactFace[i] = false;
        }

        switch (intactFace.len < intactVertex.len) {
            true => { // more vertices than faces
                const vertexCount = intactVertex.len;
                while (i < vertexCount) : (i += 1) {
                    intactVertex[i] = false;
                }
            },
            false => { // more faces than vertices
                const facecount = intactFace.len;
                while (i < facecount) : (i += 1) {
                    intactFace[i] = false;
                }
            },
        }

        // ----- set intact indices to true -----
        for (edges) |HE| {
            intactVertex[HE.origin] = true; // Vertex is mentioned
            intactFace[@divExact(HE.i_face.?, 3)] = true; // Face is mentioned
        }

        // ===== Realocate indices =====
        const indices = mesh.indices;
        const vertices = mesh.vertices;

        const vertexMoved: []?u32 = try allocator.alloc(?u32, intactVertex.len);
        defer allocator.free(vertexMoved);
        for (0..vertexMoved.len) |q| vertexMoved[q] = null; // initialize to null
        var i_validFace: usize = std.mem.indexOfScalar(bool, intactFace, true) orelse intactFace.len; // Stores index of used-face
        var i_vertexSpot: usize = std.mem.indexOfScalar(bool, intactVertex, false) orelse intactVertex.len; // Stores unused spot in vertices which may be used to store a used-vertex
        var i_faceSpot: usize = std.mem.indexOfScalar(bool, intactFace, false) orelse intactFace.len; // Stores unused spot in indices which may be used to store a used-face

        // // ===== Debug print =====
        // if(edges.len == 2976){
        //     std.debug.print("\n\nLAST UPDATE BEFORE ERROR\n", .{});
        //     std.debug.print("faceCount: {}\n", .{faceCount});
        //     std.debug.print("edges.len: {}\n", .{edges.len});

        //     std.debug.print("\nIntactFaces:\n", .{});
        //     for(0..200)|l| std.debug.print("{:<3}: {}\n", .{l, intactFace[l]});

        // }
        // {
        //     const indices_prior_long = try allocator.alloc(u32, indices.len);
        //     var k:usize = 0;
        //     for(intactFace, 0..) | b, l | {
        //         if(b){
        //             @memcpy(indices_prior_long[k*3..][0..3], indices[l*3..][0..3]);
        //             k+=1;
        //         }
        //     }
        //     var uniqueVertices:usize = 0;
        //     for(intactVertex) | b | {if(b) uniqueVertices += 1;}
        //     std.debug.print("vertexCount: {}\nEdges.len: {}\n", .{uniqueVertices, edges.len});

        //     std.debug.print("\nedges:\n", .{});
        //     std.debug.print("Edge       | Origin     | Twin       | Next       | Prev       | i_face     |\n", .{});
        //     for(edges, 0..)| edge, k2 | {
        //         const edge_ind = k2;
        //         const origin = edge.origin;
        //         const twin = edge.twin;
        //         const next_ = edge.next;
        //         const prev = edge.prev;
        //         const face = edge.i_face;
        //         std.debug.print("{d:<10} | {d:<10} | {d:<10} | {d:<10} | {d:<10} | {?:<10} |\n", .{edge_ind, origin, twin, next_, prev, face});
        //     }

        //     const indices_prior = try allocator.realloc(indices_prior_long, k*3);
        //     defer allocator.free(indices_prior);

        //     std.debug.print("indices_prior:\n", .{});
        //     for(0..k)| k2|{
        //         util_print.printVector(u32, indices_prior[k2*3..][0..3].*);
        //     }

        //     var hm = std.AutoHashMap([3]u32, bool).init(allocator);
        //     defer hm.deinit();
        //     std.debug.print("Vertices:\n", .{});
        //     for(0..mesh.vertexCount)| k2|{
        //         const vertex = mesh.vertices[k2*3..][0..3].*;
        //         std.debug.print("{:<3}({:<3}): ", .{k2, intactVertex[k2]});
        //         util_print.printVector(f32, vertex);

        //         const vertexKey: [3]u32 = .{@as(u32, @bitCast(math.roundTo(f32, @abs(vertex[0]), 6))),
        //                                     @as(u32, @bitCast(math.roundTo(f32, @abs(vertex[1]), 6))),
        //                                     @as(u32, @bitCast(math.roundTo(f32, @abs(vertex[2]), 6)))}; // Assumes values always larger then 0
        //         if(intactVertex[k2]){
        //             const hm_result = try hm.getOrPut(vertexKey);
        //             if(hm_result.found_existing){
        //                 return error.Unexpected;
        //             }
        //         }
        //     }

        //     // std.debug.print("Checking manifold-ness during mesh-assembly in indices_prior...\n", .{});
        //     // try indices_manifoldCheck(allocator, indices_prior);

        // }
        // // ===== Debug print =====

        i = 0;
        while (i < faceCount) : (i += 1) {
            // // ===== Debug print =====
            // if(edges.len == 2976 and i < 100){
            //     std.debug.print("i_validFace: {}\n", .{i_validFace});
            // }
            // // ===== Debug print =====

            // ----- find valid face -----
            const faceIndices = indices[i_validFace * 3 ..][0..3];

            // ----- try to move vertices down -----
            for (faceIndices, 0..) |i_vertex, k| {
                if (vertexMoved[i_vertex]) |spot| { // If vertex has been moved before
                    faceIndices[k] = spot; // replace indice reference
                } else { // If vertex is in original position
                    if (i_vertex > i_vertexSpot) { // if there is a spot free in a lower index
                        vertexMoved[i_vertex] = @intCast(i_vertexSpot); // note where vertex is moving
                        faceIndices[k] = @intCast(i_vertexSpot); // move indice reference

                        intactVertex[i_vertex] = false; // remove vertex from current spot
                        intactVertex[i_vertexSpot] = true;

                        @memcpy(vertices[i_vertexSpot * 3 ..][0..3], vertices[i_vertex * 3 ..][0..3]); // move vertex to free spot
                        i_vertexSpot = std.mem.indexOfScalarPos(bool, intactVertex, i_vertexSpot + 1, false) orelse intactVertex.len; // look for next free spot
                    }
                }
            }

            // std.debug.print("i_faceSpot/i_validFace: {}/{}\n", .{i_faceSpot, i_validFace});

            // ----- try to move face down in indices -----
            if (i_faceSpot < i_validFace) { // if there is a spot free in a lower index
                intactFace[i_validFace] = false; // Remove face from current spot
                intactFace[i_faceSpot] = true;
                @memcpy(indices[i_faceSpot * 3 ..][0..3], faceIndices); // move face
                i_faceSpot = std.mem.indexOfScalarPos(bool, intactFace, i_faceSpot + 1, false) orelse intactFace.len; // look for next free spot
            }

            // ----- find next intact face -----
            i_validFace = std.mem.indexOfScalarPos(bool, intactFace, i_validFace + 1, true) orelse break; // Find intact face -> if no more to be found stop loop
        }

        // ----- trim memory to used-portion -----
        mesh.vertexCount = @intCast(i_vertexSpot); // Index of first unused memory spot
        mesh.triangleCount = @intCast(faceCount);
        mesh.vertices = try allocator.realloc(mesh.vertices, mesh.vertexCount * 3);
        mesh.indices = try allocator.realloc(mesh.indices, mesh.triangleCount * 3);

        if (mesh.vertexCount - 1 < std.mem.max(u32, mesh.indices)) std.debug.print("Indices refer to non-existing vertex\n", .{});

        // // ===== DEBUG PRINT =====
        // const lastFaceIndices = mesh.indices[(i_faceSpot-1)*3..][0..3];
        // std.debug.print("last face[{}]: ({}, {}, {})\n", .{i_faceSpot-1, lastFaceIndices[0], lastFaceIndices[1], lastFaceIndices[2]});
        // const firstFaceIndices = mesh.indices[0..3];
        // std.debug.print("first face[{}]: ({}, {}, {})\n", .{i_faceSpot-1, firstFaceIndices[0], firstFaceIndices[1], firstFaceIndices[2]});
        // {
        //     var l:usize = 0;
        //     for(intactFace[faceCount..])|b| {if(b) l+=1;}
        //     std.debug.print("Intact vertices after", .{});
        //     std.debug.print("Intact faces after faceCount: {} - {}", .{faceCount, l});
        // }

        // if(edges.len == 2976) {
        //     std.debug.print("indices[0..3]: ({}, {}, {})\n", .{mesh.indices[0], mesh.indices[1], mesh.indices[2]});
        //     std.debug.print("indices[3..6]: ({}, {}, {})\n", .{mesh.indices[3], mesh.indices[4], mesh.indices[5]});
        //     std.debug.print("indices[63..66]: ({}, {}, {})\n\n", .{mesh.indices[63], mesh.indices[64], mesh.indices[65]});

        //     // std.debug.print("EXTENDING vertices 1 and 3\n", .{});
        //     // mesh.vertices[9] *= 1.3;
        //     // mesh.vertices[10] *= 1.3;
        //     // mesh.vertices[11] *= 1.3;
        //     // mesh.vertices[3] *= 1.3;
        //     // mesh.vertices[4] *= 1.3;
        //     // mesh.vertices[5] *= 1.3;

        //     std.debug.print("Checking manifold-ness after mesh-assembly in indices_prior...\n", .{});
        //     try indices_manifoldCheck(allocator, mesh.indices);

        //     std.debug.print("vertexCount: {}\n", .{mesh.vertexCount});
        //     std.debug.print("triangles: {} or {}\n", .{mesh.triangleCount, @divExact(mesh.indices.len, 3)});
        //     std.debug.print("\n======= Construction =======\n", .{});
        // }

        // // ===== DEBUG PRINT =====
    }

    const SurrogateLink = struct {
        originalIndex: u32,
        value: f32,
    };

    fn surrogateCompare(_: void, s1: SurrogateLink, s2: SurrogateLink) bool {
        return s1.value < s2.value;
    }

    fn errInfoCompare(_: void, e1: EdgeErrInfo, e2: EdgeErrInfo) bool {
        return e1.err < e2.err;
    }

    fn flagErrCompare(itemError: f32, flag: FlagItem) std.math.Order {
        const a = flag.err;

        if (itemError == a) {
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

        if (cutOffValue == a) {
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
    fn chainCheck(self: LinkedErrors, HE: []HalfEdge) !void {
        var i: u32 = self.valueFlags.items[0].index;
        var debug: usize = 0;
        while (i != self.linkEnd) : (i = self.linkedList[i].i_next) {
            debug += 1;
            if (debug > HE.len) return error.Unexpected;
            // std.debug.print("{}|", .{i});
            // ===== Check twins =====
            if (i != HE[HE[i].twin].twin) {
                std.debug.print("halfEdges[{0}].twin = {1}\nhalfEdges[{1}].twin = {2} != {0}\n", .{ i, HE[i].twin, HE[HE[i].twin].twin });
                return error.Unexpected;
            }

            // ===== Check next =====
            if (i != HE[HE[i].next].prev) return error.Unexpected;

            // ===== Check previous =====
            if (i != HE[HE[i].prev].next) return error.Unexpected;

            // ===== Check face validity =====
            if (HE[i].origin == HE[HE[i].next].origin or HE[i].origin == HE[HE[i].prev].origin) {
                std.debug.print("\nINVALID TRIANGLE\n", .{});
                std.debug.print("HalfEdges[{}].origin = {}\n", .{ i, HE[i].origin });
                if (HE[i].origin == HE[HE[i].next].origin) {
                    std.debug.print("HalfEdges[{0}].next = {1} and HalfEdges[{1}].origin = {2} == {3}\n", .{ i, HE[i].next, HE[HE[i].next].origin, HE[i].origin });
                } else {
                    std.debug.print("HalfEdges[{0}].next = {1} and HalfEdges[{1}].origin = {2} == {3}\n", .{ i, HE[i].prev, HE[HE[i].prev].origin, HE[i].origin });
                }
                return error.Unexpected;
            }
        }

        // std.debug.print("\n", .{});
    }

    /// Validates that no edge in subset `edges` has 3 or more connected faces
    fn he_manifoldCheck(allocator: Allocator, edges: []HalfEdge, HE: []HalfEdge) !void {
        const edgeInfo = struct {
            faceCount: u8 = 0,
            edge_index: ?u32, // Only used for singular edges to check border-properties
        };
        var hashMap = std.AutoHashMap([2]u32, edgeInfo).init(allocator);

        for (edges, 0..) |edge, i| {
            const v_root = edge.origin;
            const v_end = HE[edge.next].origin;

            const edge_vertices: [2]u32 = if (v_root < v_end) [2]u32{ v_root, v_end } else [2]u32{ v_end, v_root };

            const hm_results = try hashMap.getOrPut(edge_vertices);
            if (!hm_results.found_existing) {
                hm_results.value_ptr.* = edgeInfo{ .faceCount = 1, .edge_index = @intCast(i) };
            } else {
                hm_results.value_ptr.faceCount += 1;
            }
        }

        var value_iterator = hashMap.valueIterator();
        while (value_iterator.next()) |value_ptr| {
            if (value_ptr.faceCount > 2) {
                return LinkedErrorsErrors.ManifoldEdge;
            } else if (value_ptr.faceCount == 1) {
                const edge = value_ptr.edge_index.?;
                if (HE[HE[edge].twin].i_face != null) return error.Unexpected; // Expect singular edge to border no-face
            }
        }
    }

    pub fn inChain(self: LinkedErrors, edgeInd: u32) bool {
        var i = self.valueFlags.items[0].index;
        while (i != self.linkEnd) : (i = self.linkedList[i].i_next) {
            if (i == edgeInd) return true;
        }
        return false;
    }

    fn printChain(self: LinkedErrors, maxFlag: u32) void {
        const LL = self.linkedList;
        const flags = self.valueFlags.items;

        var i = self.valueFlags.items[0].index;
        while (LL[i].i_next != LL.len) : (i = LL[i].i_next) {
            std.debug.print("|{}", .{i});
            for (flags, 0..) |flag, k| {
                if (i == flag.index) {
                    std.debug.print("<-[{}]\n", .{k});
                    if (k >= maxFlag) return;
                    break;
                }
            }
        }
    }

    /// Print first `n` items in `self.linkedList`
    fn printChainItems(self: LinkedErrors, n: usize) void {
        const LL = self.linkedList;

        var i = self.valueFlags.items[0].index;
        var j: usize = 0;
        std.debug.print("Item in Chain |  Edge  |  error\n", .{});
        while (LL[i].i_next != LL.len) : (i = LL[i].i_next) {
            std.debug.print("{d:<13} | {d:^6} | {d:^6.6}\n", .{ j, i, self.edgeErrors[i].err });
            j += 1;
            if (j >= n) break;
        }
    }
};

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
    err: f32,
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
