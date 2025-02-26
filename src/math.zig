const std = @import("std");
const zune = @import("zune");
const Vec3 = zune.math.Vec3;

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

/// return minimum of 2 Vec3
pub fn vec3Min(v1: Vec3, v2: Vec3) Vec3 {
    return .{
        .x = @min(v1.x, v2.x),
        .y = @min(v1.y, v2.y),
        .z = @min(v1.z, v2.z),
    };
}

/// return maximum of 2 Vec3
pub fn vec3Max(v1: Vec3, v2: Vec3) Vec3 {
    return .{
        .x = @max(v1.x, v2.x),
        .y = @max(v1.y, v2.y),
        .z = @max(v1.z, v2.z),
    };
}

// /// fast inverse sqrt
// pub fn fisqrt(v: f32) f32 {
//     v
// }
