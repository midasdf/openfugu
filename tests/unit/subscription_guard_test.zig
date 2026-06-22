const std = @import("std");
const openfugu = @import("openfugu");

test "default config is subscription-only and rejects unsafe auth" {
    const cfg = openfugu.config.Config.default();

    try std.testing.expect(cfg.subscription.only);
    try std.testing.expect(!openfugu.config.authAllowed(cfg.subscription, .api_key));
    try std.testing.expect(!openfugu.config.authAllowed(cfg.subscription, .unauthenticated));
    try std.testing.expect(!openfugu.config.authAllowed(cfg.subscription, .unknown));
    try std.testing.expect(openfugu.config.authAllowed(cfg.subscription, .subscription));
}

test "subscription-only environment strips known api key variables" {
    const keys = [_][]const u8{
        "PATH",
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "GOOGLE_API_KEY",
        "HOME",
    };
    const kept = try openfugu.environment.filterKeys(std.testing.allocator, &keys, openfugu.fake.knownApiKeyEnv());
    defer std.testing.allocator.free(kept);

    try std.testing.expectEqualSlices([]const u8, &.{ "PATH", "HOME" }, kept);
}

test "redaction removes secret values from diagnostic text" {
    const input = "OPENAI_API_KEY=sk-live ANTHROPIC_API_KEY=secret CODEx";
    const redacted = try openfugu.config.redactKnownSecrets(std.testing.allocator, input);
    defer std.testing.allocator.free(redacted);

    try std.testing.expect(std.mem.indexOf(u8, redacted, "sk-live") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "CODEx") != null);
}
