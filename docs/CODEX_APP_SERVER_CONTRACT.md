# Codex App Server runtime contract

Status: implementation candidate; CLI 0.156.0 is explicitly incompatible for production until effective-layer isolation, transcript replay, model-visible tool inventory, account setup, and the product-consumer gates pass dedicated Actions acceptance.

## Pinned runtime and protocol

- CLI package: `@openai/codex` `0.156.0`.
- Source revision: [`rust-v0.156.0`](https://github.com/openai/codex/tree/rust-v0.156.0).
- Transport: one bounded native Mach-O `codex app-server --strict-config` subprocess using JSONL over stdin/stdout. The official npm launcher is resolved to its packaged arm64 binary; an unresolved script/wrapper is rejected so cancellation owns the actual process.
- Default combined schema SHA-256: `eb1ba91bd0fab656523092f6ed7de3ea7aef278921a650f14dc871ae7dcfaf84`.
- Default v2 schema SHA-256: `995fc3b8f8c469f6787e8fc5be4038c4f31359025edd8480b862e83355f3bf3b`.
- Experimental initialization is required because `thread/start.dynamicTools`, `thread/start.environments`, and `thread/start.runtimeWorkspaceRoots` are experimental in this revision.

The hashes were produced from the installed package with:

```text
codex app-server generate-json-schema --out <temporary-directory>
```

This export does not start App Server, authenticate, query models, or prove runtime compatibility. The default export intentionally omits experimental request fields; their contract is bound to the pinned source for [`ThreadStartParams`](https://github.com/openai/codex/blob/rust-v0.156.0/codex-rs/app-server-protocol/src/protocol/v2/thread.rs) and the upstream [App Server protocol guide](https://github.com/openai/codex/blob/rust-v0.156.0/codex-rs/app-server/README.md).

## Isolation boundary

NexGenVideo supplies a stable dedicated `CODEX_HOME` under Application Support and a per-runtime scratch directory under Caches. The home is not versioned because the supported keyring identity includes the canonical home path. The host points `HOME` and all XDG roots into those locations, uses a system-only `PATH`, writes its own strict user configuration, and passes only an allowlisted environment. It never reads or copies `~/.codex`, auth files, personal MCP servers, plugins, skills, hooks, project instructions, or Desktop conversations.

`--strict-config` validates fields; it does not isolate layers. CLI 0.156.0 still loads packaged defaults, `/etc/codex`, MDM, enterprise-cloud, project, and legacy-managed layers. After initialization and again immediately before `thread/start`, NexGenVideo first calls `config/read(includeLayers: true)` and `configRequirements/read`. It requires its exact user layer, an empty system layer, no active managed/project/legacy/session layer, no managed requirements, and the expected effective provider/sandbox/approval/web boundary. Only after that check passes does it call `mcpServerStatus/list` and `skills/list`, because the pinned MCP status implementation eagerly starts configured servers while collecting their tools. Those inventories must be empty. Any unreadable or incompatible result stops before a thread or model request. The adversarial Actions fixture places a foreign MCP in `/etc/codex/config.toml` and requires rejection before MCP inventory or launch.

The pinned source initializes thread MCP/tool state inside `thread/start`, after these checks. The CLI does not offer a switch that prevents system/managed layers from being loaded, however, and the checks cannot make a mutable system layer atomic with the later start. This residual boundary and the actual model-visible inventory must pass on the target runner; the implementation does not claim OS-level hermeticity or production compatibility.

The isolated home uses the supported `cli_auth_credentials_store = "keyring"` mechanism. The upstream keyring key is derived from the canonical Codex home, so a personal CLI login is deliberately not visible. A missing isolated login stops after the configuration/MCP/skills inventory and `account/read`; it does not call `model/list`, start a thread, probe a model, or select a paid fallback. API-key and ChatGPT billing modes come from `account/read`. The app does not yet expose the supported `account/login/start` flow, so production account setup remains a blocker and the UI does not claim that Settings can perform it.

For each new thread the host sends:

- `ephemeral: true`, so the incompatible cold-resume format is not persisted as usable provider session state;
- `environments: []` and `runtimeWorkspaceRoots: []`, which remove local execution environments and their shell/patch tools;
- `allowProviderModelFallback: false`, so the runtime cannot silently change provider or billing path;
- `modelProvider: "openai"`, matching the effective configuration verified before the start;
- `sandbox: "read-only"` and `approvalPolicy: "never"` as defense in depth;
- one `nexgen` dynamic-tool namespace containing only host-owned JSON schemas;
- the complete localized host instructions, pack identity, current phase, and packaged phase instructions;
- explicit feature/config disablement for shell, image view/generation, web, apps, plugins, skills, hooks, collaboration, browser/computer use, plan, and provider dialogs.

The driver retains the launched native process until its termination handler confirms exit. Stop sends `SIGTERM`, escalates only the same still-running PID after the grace period, closes pending RPCs, and removes only the uniquely created runtime scratch directory. It does not signal an unproven process group.

`instructionSources` and runtime workspace roots in every start response must be empty. Any dangerous unknown server request, current-turn notification, thread-item capability, namespace, or tool fails closed. Informative `configWarning`, `warning`, and `deprecationNotice` events are accepted without treating them as capabilities; identifiable events from an older thread or turn are discarded. Tool results preserve typed text and image blocks. Audio and video remain host-inspected assets, not claimed native model inputs.

## Why 0.156.0 is still pending

The pinned source has an internal `ToolPolicy` startup ceiling, but the public App Server start API does not expose its `allowed_tools` field. The known configuration plus empty environments removes the dangerous local surfaces in source, but that is not evidence of the final model-visible request. Compatibility therefore remains disabled in normal app runs. `NGV_CODEX_APP_SERVER_ACCEPTANCE=1` is reserved for the dedicated approved Actions run.

That acceptance must capture the actual provider request and classify the complete advertised tool surface. Dangerous built-ins or foreign MCP/app tools are incompatible even if the sandbox would later deny execution. A non-mutating clock capability alone is recorded but is not treated as a host-gate bypass.

This check cannot be replaced by configuration inspection. In the pinned [tool planner](https://github.com/openai/codex/blob/rust-v0.156.0/codex-rs/core/src/tools/spec_plan.rs), model catalog metadata can independently enable the built-in async-user-message and clock tools even when their feature flags are false. The adapter rejects every non-`item/tool/call` request and every non-`nexgen` namespace, but rejection after advertisement is not a sufficient isolation proof.

There is a confirmed native cold-resume incompatibility. In the pinned [`thread/resume` processor](https://github.com/openai/codex/blob/rust-v0.156.0/codex-rs/app-server/src/request_processors/thread_processor.rs), a cold thread is restored through `resume_thread_with_history`; the pinned [`ThreadManager`](https://github.com/openai/codex/blob/rust-v0.156.0/codex-rs/core/src/thread_manager.rs) then uses `StartThreadOptions::new`, which defaults `dynamic_tools` to empty and `environments` to `None`. NexGenVideo still rejects `thread/resume` and does not advertise `resumeNativeSession`.

For host-driven rotation, including language and phase changes, the adapter instead starts a newly checked ephemeral thread with the current full host instructions and schemas, then appends the canonical prior transcript through pinned `thread/injectItems` before the next user turn. User/assistant text, user images, namespaced function calls, typed function outputs, hidden host messages, and success/error state are mapped explicitly; an unrepresentable item refuses the replay. Failures and cancellation invalidate the old adapter, so a later send must use this replay path and can never open a silent empty thread. Deterministic fixtures and a guarded live replay scenario are prepared, but the path remains production-incompatible until the Actions run proves the pinned server consumes it as specified.

The Codex picker and durable backend preference remain out of scope and disabled.

## Required acceptance evidence

The approved Actions run must retain redacted evidence for:

1. exact CLI/package version, generated schema hashes, initialize/initialized, isolated `codexHome`, and strict-config success;
2. isolated account status and billing mode before any model or model-list request;
3. the actual model catalog and input modalities used by the later discovery contract;
4. complete model-visible tool inventory, including the adversarial system-config fixture and an honest classification of harmless versus gate-bypassing capabilities;
5. text, actual image data, `nexgen` tool call/result with typed image output, dialog/spend suspension, and localized phase instructions;
6. two chats and projects, warm dialogue continuity, host-transcript replay after language/phase rotation, explicit native cold-resume rejection, cancel/resend with a late old response, wrong runtime identity, EOF, timeout, crash, offline/auth expiry, unknown events, and reconnect/reinitialization joining the existing host phase job;
7. process-tree exit and absence of secrets, prompts, tokens, or raw tool payloads in Actions logs.

The real LLM smoke is a separately approved paid step. Normal CI covers only deterministic protocol/consumer fixtures.
