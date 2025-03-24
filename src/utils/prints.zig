const std = @import("std");

pub fn printVector(T: type, v: [3]T) void {
    switch (@typeInfo(T)) {
        .float => std.debug.print("({d:<9.5}, {d:<9.5}, {d:<9.5})\n", .{v[0], v[1], v[2]}),
        .int => std.debug.print("({d:<9}, {d:<9}, {d:<9})\n", .{v[0], v[1], v[2]}),
        else => return,
    }
    
}


pub fn print_CM_4Matd(m:[16]f64) void {
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