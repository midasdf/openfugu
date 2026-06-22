const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    if (init.environ_map.contains("OPENAI_API_KEY")) return 9;
    return 0;
}
