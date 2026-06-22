const std = @import("std");
const openfugu = @import("openfugu");

test "heuristic planner creates one-shot chain fan-out and repair plans" {
    var one = try openfugu.heuristic.plan(std.testing.allocator, .{ .request = "fix src/main.zig typo" });
    defer openfugu.planner.deinitPlan(std.testing.allocator, &one);
    try std.testing.expectEqual(openfugu.types.Topology.one_shot, one.topology);
    try std.testing.expectEqual(@as(usize, 1), one.nodes.len);
    try std.testing.expectEqual(openfugu.types.Role.worker, one.nodes[0].role);

    var chain = try openfugu.heuristic.plan(std.testing.allocator, .{ .request = "investigate broad failing tests" });
    defer openfugu.planner.deinitPlan(std.testing.allocator, &chain);
    try std.testing.expectEqual(openfugu.types.Topology.chain, chain.topology);
    try std.testing.expectEqual(openfugu.types.Role.thinker, chain.nodes[0].role);
    try std.testing.expectEqual(openfugu.types.Role.worker, chain.nodes[1].role);

    var fan = try openfugu.heuristic.plan(std.testing.allocator, .{ .request = "compare two independent implementations" });
    defer openfugu.planner.deinitPlan(std.testing.allocator, &fan);
    try std.testing.expectEqual(openfugu.types.Topology.fan_out_fan_in, fan.topology);
    try std.testing.expectEqual(@as(usize, 3), fan.nodes.len);

    var repair = try openfugu.heuristic.repair(std.testing.allocator, 9);
    defer openfugu.planner.deinitPlan(std.testing.allocator, &repair);
    try std.testing.expectEqual(openfugu.types.Intent.repair, repair.nodes[0].intent);
    try std.testing.expectEqual(openfugu.types.ContextRef{ .verification = 9 }, repair.nodes[0].access[0]);
}

test "validator rejects cycles and accepts forward-only dependencies" {
    const ids = [_]openfugu.types.NodeId{2};
    const cycle_dep = [_]openfugu.types.NodeId{1};
    const nodes = [_]openfugu.types.PlanNode{
        .{
            .id = 1,
            .role = .worker,
            .intent = .implement,
            .selector = .any_healthy,
            .instruction = "a",
            .depends_on = &ids,
            .access = &.{.original_request},
            .creates_candidate = true,
        },
        .{
            .id = 2,
            .role = .worker,
            .intent = .implement,
            .selector = .any_healthy,
            .instruction = "b",
            .depends_on = &cycle_dep,
            .access = &.{.original_request},
            .creates_candidate = true,
        },
    };
    const finals = [_]openfugu.types.NodeId{2};
    const plan: openfugu.types.WorkflowPlan = .{
        .topology = .chain,
        .nodes = @constCast(&nodes),
        .final_nodes = &finals,
        .rationale = "cycle",
    };

    try std.testing.expectError(error.CyclicDependency, openfugu.validate.validatePlan(plan));
}

test "subscription planner accepts minimal validated json plan" {
    const raw =
        \\{"topology":"one_shot","nodes":[{"id":1,"role":"worker","intent":"implement","instruction":"apply fix","creates_candidate":true}],"final_nodes":[1],"rationale":"direct"}
    ;
    var plan = try openfugu.subscription_agent.planOrFallback(std.testing.allocator, .{
        .original_request = "fallback request",
        .safe_repo_summary = "summary",
    }, raw);
    defer openfugu.planner.deinitPlan(std.testing.allocator, &plan);

    try std.testing.expectEqual(openfugu.types.Topology.one_shot, plan.topology);
    try std.testing.expectEqual(@as(usize, 1), plan.nodes.len);
    try std.testing.expectEqual(@as(openfugu.types.NodeId, 1), plan.nodes[0].id);
    try std.testing.expectEqual(openfugu.types.Role.worker, plan.nodes[0].role);
    try std.testing.expectEqual(openfugu.types.Intent.implement, plan.nodes[0].intent);
    try std.testing.expectEqualStrings("apply fix", plan.nodes[0].instruction);
    try std.testing.expectEqual(@as(openfugu.types.NodeId, 1), plan.final_nodes[0]);
}

test "subscription planner accepts two node chain json plan" {
    const raw =
        \\{"topology":"chain","nodes":[{"id":1,"role":"thinker","intent":"analyze","instruction":"inspect","creates_candidate":false},{"id":2,"role":"worker","intent":"implement","instruction":"apply fix","depends_on":[1],"access":[{"node_output":1}],"creates_candidate":true}],"final_nodes":[2],"rationale":"think then act"}
    ;
    var plan = try openfugu.subscription_agent.planOrFallback(std.testing.allocator, .{
        .original_request = "fallback request",
        .safe_repo_summary = "summary",
    }, raw);
    defer openfugu.planner.deinitPlan(std.testing.allocator, &plan);

    try std.testing.expectEqual(openfugu.types.Topology.chain, plan.topology);
    try std.testing.expectEqual(@as(usize, 2), plan.nodes.len);
    try std.testing.expectEqual(openfugu.types.Role.thinker, plan.nodes[0].role);
    try std.testing.expectEqual(openfugu.types.Role.worker, plan.nodes[1].role);
    try std.testing.expectEqual(@as(openfugu.types.NodeId, 1), plan.nodes[1].depends_on[0]);
    try std.testing.expectEqual(openfugu.types.ContextRef{ .node_output = 1 }, plan.nodes[1].access[0]);
    try std.testing.expectEqual(@as(openfugu.types.NodeId, 2), plan.final_nodes[0]);
}

test "context broker includes only access-listed node output" {
    const outputs = [_]openfugu.context.NodeOutput{
        .{ .id = 1, .text = "allowed output" },
        .{ .id = 2, .text = "secret output" },
    };
    const access = [_]openfugu.types.ContextRef{
        .original_request,
        .{ .node_output = 1 },
    };

    const built = try openfugu.context.build(std.testing.allocator, .{
        .original_request = "original task",
        .outputs = &outputs,
        .access = &access,
        .max_bytes = 4096,
    });
    defer built.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, built.text, "original task") != null);
    try std.testing.expect(std.mem.indexOf(u8, built.text, "allowed output") != null);
    try std.testing.expect(std.mem.indexOf(u8, built.text, "secret output") == null);
}
