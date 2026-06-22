const commands = @import("commands.zig");
const model_review = @import("model_review.zig");

pub const Decision = enum {
    accept,
    reject,
};

pub const CandidateVerdictInput = struct {
    has_changes: bool,
    objective: commands.Verification,
    model_review: model_review.Review = .{},
    reverified: bool,
};

pub fn decide(input: CandidateVerdictInput) Decision {
    if (!input.has_changes) return .reject;
    if (input.objective.unverified) return .reject;
    if (!input.objective.passed) return .reject;
    if (input.model_review.required and input.model_review.rejected) return .reject;
    if (!input.reverified) return .reject;
    return .accept;
}
