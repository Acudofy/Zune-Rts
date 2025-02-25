const std = @import("std");

// Window config
pub const WINDOW_WIDTH = 1280;
pub const WINDOW_HEIGHT = 720;
pub const WINDOW_TITLE = "Zune RTS";

// Camera config
pub const CAMERA_FOV: f32 = std.math.degreesToRadians(90.0);
pub const CAMERA_ASPECT: f32 = WINDOW_WIDTH / WINDOW_HEIGHT;
pub const CAMERA_NEAR: f32 = 0.1;
pub const CAMERA_FAR: f32 = 5000;
