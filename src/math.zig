const std = @import("std");
const zune = @import("zune");
const Vec3 = zune.math.Vec3;
const Mat4 = zune.math.Mat4;

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

/// Return [3]f32 of magnitude 1
pub fn vec3returnNormal(v: @Vector(3, f32)) @TypeOf(v) {
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

pub fn Mat4Vec4(m: Mat4, v: Vec4(f32)) Vec4(f32) {
    const M = m.data;
    return .{
        .x = M[0]*v.x + M[4]*v.y + M[8]*v.z + M[12]*v.w,
        .y = M[1]*v.x + M[5]*v.y + M[9]*v.z + M[13]*v.w,
        .z = M[2]*v.x + M[6]*v.y + M[10]*v.z + M[14]*v.w,
        .w = M[3]*v.x + M[7]*v.y + M[11]*v.z + M[15]*v.w,
    };
}

// /// fast inverse sqrt
// pub fn fisqrt(v: f32) f32 {
//     v
// }
