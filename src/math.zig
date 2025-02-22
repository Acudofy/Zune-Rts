const std = @import("std");
const zune = @import("zune");
const Vec3 = zune.math.Vec3;

/// Changes vector magnitude to 1
pub fn vec3normalize(v: []f32) void {    
    const mag2 = v[0] * v[0] + v[1] * v[1] + v[2] * v[2]; // squared magnitude

    if (mag2 == 0) {
        return; // If magnitude is 0 return same vector
    }
    const r_mag = 1/std.math.sqrt(mag2); // reciprical of magnitude sqrt

    v[0] *= r_mag;
    v[1] *= r_mag;
    v[2] *= r_mag;
}

// /// fast inverse sqrt
// pub fn fisqrt(v: f32) f32 {
//     v    
// }