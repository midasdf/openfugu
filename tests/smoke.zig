const std = @import("std");
const smoke_options = @import("smoke_options");

test "real CLI smoke tests are opt-in" {
    if (!smoke_options.real_cli_tests) return error.SkipZigTest;
    // ponytail: keep smoke non-invasive; adapter auth probes can be wired here when run by a user who accepts quota use.
    std.debug.print("OPENFUGU real CLI smoke tests are enabled; no model invocation is performed by default.\n", .{});
}
