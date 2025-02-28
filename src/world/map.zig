const std = @import("std");
const zune = @import("zune");

const fImport = @import("../mesh/import_files.zig");
const mProc = @import("../mesh/processing.zig");

const inView = @import("../main.zig").inview;

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

pub const Map = struct {
    allocator: std.mem.Allocator,
    resourceManager: *zune.graphics.ResourceManager,
    camera: *zune.graphics.Camera,
    model: *zune.graphics.Model,
    positions: []Vec3(f32),
    boundingBoxes: []BoundingBox,

    inView: []bool,
    loaded: []bool,
    monitored: []bool,
    
    chunking: Vec2(usize),
    chunkSize: Vec2(f32),

    
    pub fn init(resource_manager: *zune.graphics.ResourceManager, objFileLoc: []const u8, camera: *zune.graphics.Camera, material: *zune.graphics.Material, size: Vec3(f32), chunking: Vec2(usize), mapName: []const u8) !Map {
        const allocator = resource_manager.allocator;
        
        // ===== load and chunk mesh =====
        var phMapMesh = try fImport.importPHMeshObj(resource_manager, objFileLoc);
        mProc.moveMesh(phMapMesh, phMapMesh.getBoundingBox().min.inv());
        const chunks = try mProc.chunkMesh2Model(resource_manager, &phMapMesh, material, chunking.x, chunking.y, mapName, true);
        const chunkTot = chunks.phMeshes.len;
        defer {
            for (chunks.phMeshes) | phMesh | phMesh.deinit();
            allocator.free(chunks.phMeshes);
        }

        // ===== Find chunk center positions =====
        const positions = try allocator.alloc(Vec3(f32), chunkTot);
        for (chunks.phMeshes, 0..) | phMesh, i | positions[i] = phMesh.boundingBox.min.add(phMesh.boundingBox.max.subtract(phMesh.boundingBox.min).scale(0.5)); 

        // ===== Find chunk BoundingBoxes =====
        const boundingBoxes = try allocator.alloc(BoundingBox, chunkTot);
        for (chunks.phMeshes, 0..) | phMesh, i | boundingBoxes[i] = phMesh.boundingBox;

        // ===== Create loaded/inView chunk lists =====
        const loaded = try allocator.alloc(bool, chunkTot);
        for (0..chunkTot) | i | loaded[i] = false; 
        const viewed = try allocator.alloc(bool, chunkTot);
        @memcpy(viewed, loaded);
        const monitored = try allocator.alloc(bool, chunkTot);
        @memcpy(monitored, loaded);

        // ===== Construct & return Map =====

        var result = Map{
            .allocator = allocator,
            .resourceManager = resource_manager,
            .camera = camera,
            .model = chunks.model,
            .positions = positions,
            .boundingBoxes = boundingBoxes,

            .inView = viewed,
            .loaded = loaded,
            .monitored = monitored,
            
            .chunking = chunking,
            .chunkSize = .{.x = size.x/(@as(f32, @floatFromInt(chunking.x))), .y = size.z/(@as(f32, @floatFromInt(chunking.y)))}
        };
        try result.initView();
        return result;
    }

    pub fn deinit(self: Map) void {
        self.allocator.free(self.positions);
        self.allocator.free(self.boundingBoxes);
        self.allocator.free(self.inView);
        self.allocator.free(self.loaded);
        self.allocator.free(self.monitored);
    }

    pub fn updateLoaded(self: *Map) void {
        
        // ===== Set variables =====
        const monitored = self.monitored;
        
        // ===== Set inView chunks =====
        var i:usize = 0;
        while(i<monitored.len):(i+=1){
            if(monitored[i]){
                const viewed = inView(self.camera, self.positions[i]);

                if(viewed and !self.inView[i]){
                    self.updateViewed(i, true);
                }
                if(!viewed and self.inView[i]){
                    self.updateViewed(i, false);
                }
            }
        }
    }

    pub fn initView(self: *Map) !void {
        const allocator = self.allocator;

        // ===== Set inView =====
        for (self.positions, 0..) | position, i | {
            const viewed = inView(self.camera, position);
            self.inView[i] = viewed;
            // ===== Set loaded =====
            if(viewed){
                self.loaded[i] = true;
                for(self.neighbourIndices(i)) | n | {
                    if(n) | i_n | {
                        self.loaded[i_n] = true;
                    }
                }
            }
        }

        // ===== Set monitored =====
        var i: usize = 0;
        while(!self.inView[i]):(i+=1){if (i+1 >= self.loaded.len) break;}

        const outerIndices = try self.roamIndices(self.loaded, i);
        const innerIndices = try self.roamIndices(self.inView, i);
        defer allocator.free(outerIndices);
        defer allocator.free(innerIndices);

        for(outerIndices) | i_outer | {
            self.monitored[i_outer] = true;
        }
        for(innerIndices) | i_inner | {
            self.monitored[i_inner] = true;
        }
    }

    const roamError = error{DeadEndSearch};
    fn roamIndices(self: Map, list: []bool, i_start: usize) ![]usize {
        // ===== Determine constants =====
        const row = self.chunking.x;
        const i_hist = try self.allocator.alloc(usize, self.positions.len);

        // ===== Find edge =====
        var i: usize = i_start;
        if (i!=0) {
            while(!list[i-1] and @rem(i, row) != 0){
                if (list[i]) break;
                i -= 1;
            }
        }
        i_hist[0] = i; // store first indice

        const cardinal: [4]usize = .{0, row+1, row+row, row-1}; // implicit -row
        var dir: u8 = 1;
        var c: usize = 1;
        while(i != i_hist[0]):(c+=1){
            // ----- try all cardinal directions inc. previous -----
            for (dir-1..dir+1) | d | {
                const d_mod = @mod(d, 4);
                const car = cardinal[d_mod];
                if (i + car>row) continue; // i_next is negative
                const i_next = i + car - row;
                if (i_next >= list.len) continue; // i_next is too large
                if(list[i_next]){
                    i = i_next;
                    if(d == dir+1) dir +=1;
                    continue;
                }
            }

            // ----- store new found indice -----
            i_hist[c] = i;
            if (i_hist[c] == i_hist[c-1]) return roamError.DeadEndSearch;
        }

        return try self.allocator.realloc(i_hist, c); // skip last element-> same as first
    }

    fn neighbourIndices(self: Map, i:usize) [8]?usize {
        const x = @rem(i, self.chunking.x);
        const y = @divFloor(i, self.chunking.x);

        const row = self.chunking.x;
        const col = self.chunking.y;
        return  .{  if(y == 0 or x == 0) null else i-row-1,
                    if(y == 0) null else i-row,
                    if(y == 0 or x == row-1) null else i-row+1,
                    if(x == row-1) null else i+1,
                    if(y == col-1 or x == row-1) null else i+row+1,
                    if(y == col-1) null else i+row,
                    if(y == col-1 or x == 0) null else i+row-1,
                    if(x == 0) null else i-1
                };
    }

    fn directNeighbourIndices(self: Map, i:usize) [4]?usize {
        const x = @rem(i, self.chunking.x);
        const y = @divFloor(i, self.chunking.x);

        const row = self.chunking.x;
        const col = self.chunking.y;
        return  .{  if(y == 0) null else i-row,
                    if(x == row) null else i+1,
                    if(y == col) null else i+row,
                    if(x == 0) null else i-1
                };
    }

    /// Update surrounding state of `self.monitored` and `self.loaded` given the `self.inview` state of the center index
    fn updateViewed(self: *Map, i_center: usize, i_state: bool) void {
        if(i_state){
            self.inView[i_center] = true;
            for(self.neighbourIndices(i_center)) | n |{
                if(n) | i_n | {
                    // ----- if added index -> for all neighbours routine -----
                    if(self.inView[i_n]){
                        if(self.allNeighboursInView(i_n)) self.monitored[i_n] = false;
                    } else {
                        self.loaded[i_n] = true;
                        self.monitored[i_n] = true;
                    }

                }
            }
        } else{
            self.inView[i_center] = false;
            for(self.neighbourIndices(i_center)) | n |{
                if(n) | i_n | {
                    // ----- if added index -> for all neighbours routine -----
                    if(self.inView[i_n]){
                        self.monitored[i_n] = true;
                    } else if(!self.anyNeighboursInView(i_n)){
                        self.loaded[i_n] = false;
                        self.monitored[i_n] = false;
                    }
                }
            }
        }
    }

    fn allNeighboursInView(self: Map, i_center: usize) bool {
        for(self.neighbourIndices(i_center)) | n | {
            if(n) | i_n | {
                if(!self.inView[i_n]) {
                    return false;
                } 
            }
        }
        return true;
    }
    
    fn anyNeighboursInView(self: Map, i_center: usize) bool {
        for(self.neighbourIndices(i_center)) | n | {
            if(n) | i_n | {
                if(self.inView[i_n]) {
                    return true;
                } 
            }
        }
        return false;
    }

};