const std = @import("std");

pub fn main(init: std.process.Init) !u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(init.io, "answer.txt", init.gpa, .limited(1024)) catch return 2;
    defer init.gpa.free(bytes);
    return if (std.mem.eql(u8, bytes, "good\n")) 0 else 1;
}
