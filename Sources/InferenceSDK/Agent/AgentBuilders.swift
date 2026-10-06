// Fluent builders for an agent's internal tools and lifecycle hooks. Mirrors
// sdk-js src/tool-builder.ts internalTools() and src/hook-builder.ts
// lifecycleHook() / learningHooks(). They build the generated DTOs
// (InternalToolsConfig, LifecycleHookConfig) an agent config carries.
//
//     let config = AgentConfigInput(
//         internalTools: internalTools().plan().knowledge().agent().build(),
//         hooks: learningHooks(suggest: true, learn: true))

import Foundation

// MARK: - Internal tools

/// Builds an `InternalToolsConfig`. Each call returns a copy, so a builder can
/// be shared as a base and extended. Categories left unset keep the API's
/// default.
public struct InternalToolsBuilder: Sendable {
    private var config = InternalToolsConfig()

    public init() {}

    /// Plan tools (Create, Update, Load).
    public func plan(_ enabled: Bool = true) -> Self { with { $0.plan = enabled } }

    /// Memory tools (Set, Get, GetAll).
    public func memory(_ enabled: Bool = true) -> Self { with { $0.memory = enabled } }

    /// Widget tools (UI, HTML). Top-level agents only.
    public func widget(_ enabled: Bool = true) -> Self { with { $0.widget = enabled } }

    /// The finish tool. Sub-agents only.
    public func finish(_ enabled: Bool = true) -> Self { with { $0.finish = enabled } }

    /// Meta tools.
    public func meta(_ enabled: Bool = true) -> Self { with { $0.meta = enabled } }

    /// Remote tools (run commands on the user's connected remotes).
    public func remote(_ enabled: Bool = true) -> Self { with { $0.remote = enabled } }

    /// Knowledge tools (search, read and save the user's skills and knowledge entries).
    public func knowledge(_ enabled: Bool = true) -> Self { with { $0.knowledge = enabled } }

    /// skill_get for the skills configured on the agent (on by default).
    public func skills(_ enabled: Bool = true) -> Self { with { $0.skills = enabled } }

    /// Artifact tools (publish shareable HTML/Markdown pages).
    public func artifact(_ enabled: Bool = true) -> Self { with { $0.artifact = enabled } }

    /// The agent tool (run a copy of this agent on a side task). Was `spawn`;
    /// the API still reads `spawn` as `agent`.
    public func agent(_ enabled: Bool = true) -> Self { with { $0.agent = enabled } }

    /// Plan, memory, widget and finish on. The opt-in categories (remote,
    /// knowledge, skills, artifact, agent, meta) are left as they are.
    public func all() -> Self {
        with { $0.plan = true; $0.memory = true; $0.widget = true; $0.finish = true }
    }

    /// Plan, memory, widget and finish off.
    public func none() -> Self {
        with { $0.plan = false; $0.memory = false; $0.widget = false; $0.finish = false }
    }

    public func build() -> InternalToolsConfig { config }

    private func with(_ change: (inout InternalToolsConfig) -> Void) -> Self {
        var copy = self
        change(&copy.config)
        return copy
    }
}

/// Start an internal tools configuration.
public func internalTools() -> InternalToolsBuilder { InternalToolsBuilder() }

// MARK: - Lifecycle hooks

/// Builds a `LifecycleHookConfig` for one event. The handler defaults to a
/// webhook with an empty URL, as in sdk-js; set one with `webhook`, `task` or
/// `builtin`.
public struct LifecycleHookBuilder: Sendable {
    private var hook: LifecycleHookConfig

    public init(_ event: HookEvent) {
        hook = LifecycleHookConfig(event: event, type: .hookHandlerWebhook, handler: "")
    }

    /// Handle the event with a webhook URL.
    public func webhook(_ url: String) -> Self { handler(.hookHandlerWebhook, url) }

    /// Handle the event with a task (an agent ref).
    public func task(_ agentRef: String) -> Self { handler(.hookHandlerTask, agentRef) }

    /// Handle the event with a builtin the platform runs itself (e.g. belt:suggest).
    public func builtin(_ name: BuiltinHook) -> Self { handler(.hookHandlerBuiltin, name.rawValue) }

    /// Run the handler without blocking the turn.
    public func async(_ enabled: Bool) -> Self { var copy = self; copy.hook.async = enabled; return copy }

    /// Handler timeout in seconds.
    public func timeout(_ seconds: Int) -> Self { var copy = self; copy.hook.timeout = seconds; return copy }

    public func build() -> LifecycleHookConfig { hook }

    private func handler(_ type: HookHandlerType, _ ref: String) -> Self {
        var copy = self
        copy.hook.type = type
        copy.hook.handler = ref
        return copy
    }
}

/// Start a lifecycle hook for an agent event.
public func lifecycleHook(_ event: HookEvent) -> LifecycleHookBuilder { LifecycleHookBuilder(event) }

/// The built-in learning hooks, attached to the events each one runs on.
/// - `suggest`: before each turn, add the team's matching skills, knowledge and apps to context.
/// - `learn`: every 10th user turn and before compaction, save reusable knowledge from the
///   conversation to the team's registry, deduplicated. Runs on the agent's own model, and only
///   for chats by the agent's owning team.
public func learningHooks(suggest: Bool = false, learn: Bool = false) -> [LifecycleHookConfig] {
    var hooks: [LifecycleHookConfig] = []
    if suggest {
        hooks.append(lifecycleHook(.turnStart).builtin(.beltSuggest).build())
    }
    if learn {
        for event in [HookEvent.agentComplete, .preCompact] {
            hooks.append(lifecycleHook(event).builtin(.beltExtract).build())
        }
    }
    return hooks
}
