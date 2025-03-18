const std = @import("std");
const zune = @import("zune");
const Vec3 = zune.math.Vec3;
const Mat4 = zune.math.Mat4;

pub usingnamespace @cImport(@cInclude("eigen_header.h"));

pub const mat4Identity: [16]f32 = .{1, 0, 0, 0,
                                    0, 1, 0, 0,
                                    0, 0, 1, 0,
                                    0, 0, 0, 1};

pub fn vec3(T: type) type {
    return struct {
        x: T = 0,
        y: T = 0,
        z: T = 0,
        
        const Self = @This();
        
        pub fn inv(self: Self) Self {
            return .{   .x = -self.x,
                        .y = -self.y,
                        .z = -self.z};
        }

        pub fn subtract(self: Self, v: Self) Self {
            return .{   .x = self.x-v.x,
                        .y = self.y-v.y,
                        .z = self.z-v.z};
        }

        pub fn add(self: Self, v: Self) Self {
            return .{   .x = self.x+v.x,
                        .y = self.y+v.y,
                        .z = self.z+v.z};
        }

        pub fn scale(self: Self, s: f32) Self {
            return .{   .x = self.x*s,
                        .y = self.y*s,
                        .z = self.z*s};
        }

        pub fn cross(self: Self, v: Self) Self {
            const result = vec3Cross(.{self.x, self.y, self.z}, .{v.x, v.y, v.z});
            return .{   .x = result[0],
                        .y = result[1],
                        .z = result[2]};
        }

        pub fn dot(self: Self, v: Self) T {
            return  self.x*v.x +
                    self.y*v.y +
                    self.z*v.z;
        }
    };
}

pub fn vec2(T: type) type {
    return struct {
        x: T = 0,
        y: T = 0,
    };
}

/// Changes vector magnitude to 1
pub fn vec3normalize(v: []f32) void {
    const mag2 = v[0] * v[0] + v[1] * v[1] + v[2] * v[2]; // squared magnitude

    if (mag2 == 0) {
        return; // If magnitude is 0 return same vector
    }
    const r_mag = 1 / std.math.sqrt(mag2); // reciprical of magnitude sqrt

    v[0] *= r_mag;
    v[1] *= r_mag;
    v[2] *= r_mag;
}

/// return normal of [3][3]f32 points which define face
pub inline fn getVec3Normal(v1: @Vector(3, f32), v2: @Vector(3, f32), v3: @Vector(3, f32)) [3]f32 {
    const edge1 = v2-v1;
    const edge2 = v3-v1;
    return vec3Cross(edge1, edge2);
}

pub inline fn vec3Cross(v1: @Vector(3, f32), v2: @Vector(3, f32)) [3]f32 {
    const tmp_0 = @shuffle(f32, v1, v1, @Vector(3, i32){1, 2, 0});
    const tmp_1 = @shuffle(f32, v2, v2, @Vector(3, i32){2, 0, 1});
    const tmp_2 = tmp_0*v2;
    const tmp_3 = @shuffle(f32, tmp_2, tmp_2, @Vector(3, i32){1, 2, 0});
    const tmp_4 = tmp_0*tmp_1;
    const cross = tmp_4-tmp_3;
    return cross;
}

/// Return [3]f32 of magnitude 1
pub fn vec3returnNormalize(v: @Vector(3, f32)) @TypeOf(v) {
    const mag2 = @reduce(.Add, v*v); // squared magnitude

    if (mag2 == 0) {
        return .{0, 0, 0}; // If magnitude is 0 return same vector
    }
    const r_mag: @TypeOf(v) = @splat(1 / std.math.sqrt(mag2)); // reciprical of magnitude sqrt

    return v*r_mag;
}


/// return minimum of 2 Vec3
pub fn vec3Min(v1: anytype, v2: @TypeOf(v1)) @TypeOf(v1) {
    return .{
        .x = @min(v1.x, v2.x),
        .y = @min(v1.y, v2.y),
        .z = @min(v1.z, v2.z),
    };
}

/// return maximum of 2 Vec3
pub fn vec3Max(v1: anytype, v2: @TypeOf(v1)) @TypeOf(v1) {
    return .{
        .x = @max(v1.x, v2.x),
        .y = @max(v1.y, v2.y),
        .z = @max(v1.z, v2.z),
    };
}

/// General type 4-item vector (x,y,z,w)
pub fn Vec4(T: type) type {
    return struct {
        x: T = 0,
        y: T = 0,
        z: T = 0,
        w: T = 0,
    };
}

pub inline fn Mat4Quadric(m: [16]f32, v: [3]f32) f32 {
    return  v[0]*(m[0]*v[0] + m[1]*v[1] + m[2]*v[2] + m[3]) + 
            v[1]*(m[4]*v[0] + m[5]*v[1] + m[6]*v[2] + m[7]) + 
            v[2]*(m[8]*v[0] + m[9]*v[1] + m[10]*v[2] + m[11]) + 
            (m[12]*v[0] + m[13]*v[1] + m[14]*v[2] + m[15]);
}

pub fn Mat4Vec4(m: Mat4, v: Vec4(f32)) Vec4(f32) {
    const M = m.data;
    return .{
        .x = M[0]*v.x + M[4]*v.y + M[8]*v.z + M[12]*v.w,
        .y = M[1]*v.x + M[5]*v.y + M[9]*v.z + M[13]*v.w,
        .z = M[2]*v.x + M[6]*v.y + M[10]*v.z + M[14]*v.w,
        .w = M[3]*v.x + M[7]*v.y + M[11]*v.z + M[15]*v.w,
    };
}

// /// Solve for x in Ax = b. Assumes m is symetric and negative/positive-semidefinite. m is column major and only stores lower triangle
// pub inline fn solveLDLT(m: *[16]f32, b_: [4]f32) [4]f32 {
//     var b = b_;
    
//     // ===== L-decomposition =====
//     var L: [16]f32 = .{ 1, 0, 0, 0, 
//                         0, 1, 0, 0, 
//                         0, 0, 1, 0, 
//                         0, 0, 0, 1}; // Identity
//     var Q = L; // keeps track of column switches

//     var i:u4 = 0;
//     while(i<3):(i+=1){ // i = 0, 1, 2
//         const pivot = findPivot(m, i); // Find first non-zero pivot

//         if(pivot) | p | { 
//             if (p.row != i) { // if row switch
//                 vec4ElemSwitch(&b, p.row, i); // switch rows in output
//                 CM_matrixRowSwap(&m, p.row, i); // switch rows in m
//             }
//             if (p.col != i){ // if column switch
//                 CM_matrixColSwap(&Q, p.col, i); // keep track of switch
//                 CM_matrixColSwap(&m, p.col, i); // switch columns in m
//             }
//         } else break; // if no valid pivots -> everything in lower corner == 0

//         const i_ = i*5;
//         var j:u4 = 0;
//         while(j<3-i):(j+=1){ // i = 0 -> 0, 1, 2 | i = 1 -> 0, 1 | i = 2 -> j = 0
//             switch(m[i_+1+j]){
//                 0 => continue, // skip zero-valued entries
//                 else => | den | { // make lower values 0
//                     const multiplier = den/m[i_];
//                     CM_matrixRowAddition(&m, i+1+j, i, -multiplier);
//                     CM_matrixRowAddition(&L, i+1+j, i, -multiplier);
//                 }
//             }
//         }
//     }
    
//     // ===== Calculate x for Ax=b =====
//     // https://math.stackexchange.com/questions/33474/solving-linear-systems-with-lu-decomposition-and-complete-pivoting-stupid-quest
//     const D:[4]f32 = .{m[0], m[5], m[10], m[15]}; // diagonal entries


// }

// /// Assumes m diagonal is populated
// inline fn CM_solveTriAxb(m: [16]f32, b: [4]f32) [4]f32 {
//     var result: [4]f32 = undefined;

//     if(b[0] != 0){
//         result[0] = b[0]/m[0]
//     }
// }

inline fn vec4ElemSwitch(v: *[4]f32, i_1: u4, i_2: u4) void {
    const tmp0 = v[i_1];
    v[i_1] = v[i_2];
    v[i_2] = tmp0;
}

inline fn CM_matrixColSwap(m: *[16]f32, i_1: u4, i_2: u4) void {
    const tmp0: [4]f32 = m[i_1*4..][0..4];
    
    @memcpy(m[i_1*4..][0..4], m[i_2*4..][0..4]);
    @memcpy(m[i_2*4..][0..4], tmp0);
}

inline fn CM_matrixRowSwap(m: *[16]f32, i_1: u4, i_2: u4) void {
    const tmp0: [4]f32 = .{m[i_1], m[i_1+4], m[i_1+8], m[i_1+12]};
    
    m[i_1]      = m[i_2];
    m[i_1+4]    = m[i_2+4];
    m[i_1+8]    = m[i_2+8];
    m[i_1+12]   = m[i_2+12];

    m[i_2]      = tmp0[0];
    m[i_2+4]    = tmp0[1];
    m[i_2+8]    = tmp0[2];
    m[i_2+12]   = tmp0[3];
}

/// Find valid pivot point, first in row -> then column -> then repeat procedure on diagonal
inline fn findPivot(m: [16]f32, diag_index: u4) ?struct{col:u4, row:u4} {
    var i = diag_index; // diag-entry

    while(i<4):(i+=1) { // do rook pivot on this diagonal entry: i 
        if(std.mem.indexOfNone(f32, m[i..][0..4], .{0})) | pos | { // check column
            return .{.col = i, .row = pos};
        }
        if(std.mem.indexOfNone(f32, .{m[i], m[4+i], m[8+i], m[12+i]}, .{0})) |pos| { // check row
            return .{.col = pos, .row = i};
        }
    }
    return null;
}

/// matrix row addition for triangular 4x4 column-major matrices
inline fn CM_matrixRowAddition(m: *[16]f32, destRow: u4, sourceRow: u4, multiplier: f32) void {
    m[destRow] += m[sourceRow]*multiplier;
    m[destRow+4] += m[sourceRow+4]*multiplier;
    m[destRow+8] += m[sourceRow+8]*multiplier;
    m[destRow+12] += m[sourceRow+12]*multiplier;
}

pub fn matrixInvers(m: [16]f32) [16]f32 {
    // Use LU decomposition to find inverse
    // ASSUMES: diagonal is populated

    var L:[16]f32 = .{      1, 0, 0, 0,
                            0, 1, 0, 0,
                            0, 0, 1, 0,
                            0, 0, 0, 1};
    var U:[16]f32 = m;

    // Reduce upper to upper triangular form
    var i:u4 = 0;
    while(i<3):(i+=1){
        var j:u4 = 0;
        while(j<3-i):(j+=1){
            const multiplier = U[i*5+4*j]/U[i*5];
            if (multiplier == 0) continue;
            matrixRowAddition(&U, i+j+1, i, -multiplier);
            matrixRowAddition(&L, i+j+1, i, multiplier);
        }
    }

    // Make L and U inverse of themselves such that m = LU -> m^-1 = U^-1 * L^-1
    // inverse L (inplace cuz faster?)
    L[4] *= -1;
    L[8] *= -1;
    L[9] *= -1;
    L[12] *= -1;
    L[13] *= -1;
    L[14] *= -1;

    // inverse U
    var Uinverse:[16]f32 = .{   1, 0, 0, 0,
                                0, 1, 0, 0,
                                0, 0, 1, 0,
                                0, 0, 0, 1};

    i = 4;
    while(i>0):(i-=1){ // 4,3,2,1
        const i_ = i-1; // 3,2,1,0
        const multiplier = 1/U[i_*5];

        matrixRowMul(&Uinverse, i_, multiplier);
        
        var j:u4 = i_;
        while(j>0):(j-=1){ // e.g. i = 3 -> j  = 3,2,1
            const j_ = j-1; // e.g. i = 3 -> j_ = 2,1,0
            matrixRowAddition(&Uinverse, j_, i_, U[i_*5-4*(i_-j_)]); // Index below entree in diagonal on row i, from bottom to top
        }
    }

    // Compute inverse of m using m = LU -> m^-1 = U^-1 * L^-1

    return matrixMul(Uinverse, L);
}

inline fn matrixRowAddition(m: *[16]f32, destRow: u4, sourceRow: u4, multiplier: f32) void {
    // Multiplies 'sourceRow' of matrix 'm' with 'multiplier', adds product to destRow

    const destInd   = destRow*4;
    const sourceInd = sourceRow*4;

    m[destInd] += m[sourceInd]*multiplier;
    m[destInd+1] += m[sourceInd+1]*multiplier;
    m[destInd+2] += m[sourceInd+2]*multiplier;
    m[destInd+3] += m[sourceInd+3]*multiplier;
}


inline fn matrixRowMul(m: *[16]f32, destRow: u4, multiplier: f32) void {
    // Multiplies 'sourceRow' of matrix 'm' with 'multiplier', adds product to destRow

    const destInd   = destRow*4;

    m[destInd] *= multiplier;
    m[destInd+1] *= multiplier;
    m[destInd+2] *= multiplier;
    m[destInd+3] *= multiplier;
}

fn matrixMul(A:[16]f32, B:[16]f32) [16]f32 {
    // const result: [16]f32 = undefined;
    
    const v1 = matrixVecMul(A, .{B[0], B[4], B[8],  B[12]});
    const v2 = matrixVecMul(A, .{B[1], B[5], B[9],  B[13]});
    const v3 = matrixVecMul(A, .{B[2], B[6], B[10], B[14]});
    const v4 = matrixVecMul(A, .{B[3], B[7], B[11], B[15]});
    
    return .{   v1[0], v2[0], v3[0], v4[0],
                v1[1], v2[1], v3[1], v4[1],
                v1[2], v2[2], v3[2], v4[2],
                v1[3], v2[3], v3[3], v4[3]};
}

fn matrixVecMul(A: [16]f32, b:[4]f32) [4]f32 {
    return .{   b[0] * A[0]  + b[1] * A[1]  + b[2] * A[2]  + b[3] * A[3],
                b[0] * A[4]  + b[1] * A[5]  + b[2] * A[6]  + b[3] * A[7],
                b[0] * A[8]  + b[1] * A[9]  + b[2] * A[10] + b[3] * A[11],
                b[0] * A[12] + b[1] * A[13] + b[2] * A[14] + b[3] * A[15]};
}

pub fn roundTo(T: type, value: T, decimals: T) T {
    const magn = std.math.pow(T, 10, decimals);
    return @round(value*magn)/magn;
}

// /// fast inverse sqrt
// pub fn fisqrt(v: f32) f32 {
//     v
// }
