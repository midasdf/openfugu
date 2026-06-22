pub const Role = enum {
    thinker,
    worker,
    verifier,
};

pub const Intent = enum {
    analyze,
    plan,
    implement,
    review,
    synthesize,
    repair,
    resolve_conflict,
};

pub const Topology = enum {
    one_shot,
    chain,
    fan_out_fan_in,
    race,
    refinement,
};

pub const AuthKind = enum {
    subscription,
    organization_subscription,
    api_key,
    unauthenticated,
    unknown,
};

pub const Compatibility = enum {
    supported,
    degraded,
    unsupported,
    unknown,
};

pub const Capability = struct {
    edit_files: bool = false,
    run_commands: bool = false,
    streaming: bool = false,
    structured_output: bool = false,
    schema_constrained_output: bool = false,
    read_only_mode: bool = false,
    workspace_write_mode: bool = false,
    max_context: ?usize = null,
};

pub const NodeId = u64;
pub const AgentId = []const u8;
pub const CandidateId = u64;

pub const ContextRef = union(enum) {
    original_request,
    node_output: NodeId,
    candidate_diff: CandidateId,
    verification: CandidateId,
    selected_prior: []const NodeId,
};

pub const CapabilityQuery = struct {
    edit_files: ?bool = null,
    run_commands: ?bool = null,
    structured_output: ?bool = null,
};

pub const AgentSelector = union(enum) {
    specific: AgentId,
    capability: CapabilityQuery,
    any_healthy,
};

pub const PlanNode = struct {
    id: NodeId,
    role: Role,
    intent: Intent,
    selector: AgentSelector,
    instruction: []const u8,
    depends_on: []const NodeId,
    access: []const ContextRef,
    creates_candidate: bool,
    parallel_group: ?u32 = null,
};

pub const WorkflowPlan = struct {
    topology: Topology,
    nodes: []PlanNode,
    final_nodes: []const NodeId,
    rationale: []const u8,
};

pub const EnvPolicy = enum {
    inherit_filtered,
    empty,
};

pub const Transport = enum {
    stdio,
};

pub const OutputFormat = enum {
    text,
    json,
    jsonl,
};

pub const Invocation = struct {
    executable: []const u8,
    argv: []const []const u8,
    cwd: []const u8,
    stdin: []const u8 = "",
    env_policy: EnvPolicy = .inherit_filtered,
    transport: Transport = .stdio,
    output_format: OutputFormat = .text,
};

pub const Usage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    source: enum { reported, estimated, unavailable } = .unavailable,
};

pub const Task = struct {
    id: []const u8,
    role: Role,
    intent: Intent,
    instruction: []const u8,
    worktree_path: []const u8,
    context: []const u8,
    target_files: []const []const u8,
    timeout_ms: u64,
    read_only: bool,
};

pub const TaskResult = struct {
    exit_code: ?u8,
    signal: ?u8 = null,
    final_text: []const u8,
    stdout_tail: []const u8,
    stderr_tail: []const u8,
    log_path: []const u8,
    usage: Usage = .{},
    started_ms: u64,
    ended_ms: u64,
};
