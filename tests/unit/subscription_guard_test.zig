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

test "subscription-only environment map removes known api key variables" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("PATH", "/bin");
    try env.put("OPENAI_API_KEY", "secret");
    try env.put("ANTHROPIC_API_KEY", "secret");

    openfugu.environment.stripKnownApiKeys(&env);

    try std.testing.expect(env.contains("PATH"));
    try std.testing.expect(!env.contains("OPENAI_API_KEY"));
    try std.testing.expect(!env.contains("ANTHROPIC_API_KEY"));
}

test "redaction removes secret values from diagnostic text" {
    const input = "OPENAI_API_KEY=value-to-redact ANTHROPIC_API_KEY=secret CODEx";
    const redacted = try openfugu.config.redactKnownSecrets(std.testing.allocator, input);
    defer std.testing.allocator.free(redacted);

    try std.testing.expect(std.mem.indexOf(u8, redacted, "value-to-redact") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "secret") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "CODEx") != null);
}
