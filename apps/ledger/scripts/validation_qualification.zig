const validation = @import("validation.zig");

test "Hylo portable artifact validators share the producer ceiling" {
    try validation.runPortableArtifactProducerCeilingQualification();
}
