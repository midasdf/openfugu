pub fn knownApiKeyEnv() []const []const u8 {
    return &.{
        "ANTHROPIC_API_KEY",
        "OPENAI_API_KEY",
        "GOOGLE_API_KEY",
        "GEMINI_API_KEY",
        "CODEX_API_KEY",
    };
}
