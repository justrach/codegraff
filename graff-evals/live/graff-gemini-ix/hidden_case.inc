
test "Gemini authenticates with x-goog-api-key" {
    const all = Keys{ .values = @splat("k") };
    const gemini = try all.providerFor("gemini-3.8-flash");
    try std.testing.expectEqual(Provider.Auth.goog_api_key, gemini.auth);
}
