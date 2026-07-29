const std = @import("std");

/// Historical v1 framing is isolated here because its bytes bind durable
/// definition history. Neutral definition_core consumes caller-owned framing
/// and does not own this legacy product vocabulary.
pub const closure_digest_frame = "skill-definition-closure/v1\x00";

test "closure digest frame remains byte-exact" {
    try std.testing.expectEqualStrings(
        "skill-definition-closure/v1\x00",
        closure_digest_frame,
    );
}
