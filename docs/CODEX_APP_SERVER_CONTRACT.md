# Codex App Server runtime contract

Status: implementation candidate; CLI 0.156.0 is explicitly incompatible for production until both the model-visible tool inventory and a safe cold-resume contract exist and pass dedicated Actions acceptance.

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

NexGenVideo supplies a dedicated `CODEX_HOME` under Application Support and a per-runtime scratch directory under Caches. It points `HOME` and all XDG roots into those host-owned locations, uses a system-only `PATH`, writes a complete strict configuration, and passes only an allowlisted environment. It never reads or copies `~/.codex`, auth files, personal MCP servers, plugins, skills, hooks, project instructions, or Desktop conversations.

The isolated home uses the supported `cli_auth_credentials_store = "keyring"` mechanism. The upstream keyring key is derived from the canonical Codex home, so a personal CLI login is deliberately not visible. A missing isolated login stops after `account/read`; it does not call `model/list`, start a thread, probe a model, or select a paid fallback.

For each new thread the host sends:

- `ephemeral: true`, so the incompatible cold-resume format is not persisted as usable provider session state;
- `environments: []` and `runtimeWorkspaceRoots: []`, which remove local execution environments and their shell/patch tools;
- `allowProviderModelFallback: false`, so the runtime cannot silently change provider or billing path;
- `sandbox: "read-only"` and `approvalPolicy: "never"` as defense in depth;
- one `nexgen` dynamic-tool namespace containing only host-owned JSON schemas;
- the complete localized host instructions, pack identity, current phase, and packaged phase instructions;
- explicit feature/config disablement for shell, image view/generation, web, apps, plugins, skills, hooks, collaboration, browser/computer use, plan, and provider dialogs.

`instructionSources` and runtime workspace roots in every start response must be empty. Any unknown server request, notification, thread-item capability, namespace, tool, thread id, turn id, runtime generation, project generation, or chat id fails closed. Tool results preserve typed text and image blocks. Audio and video remain host-inspected assets, not claimed native model inputs.

## Why 0.156.0 is still pending

The pinned source has an internal `ToolPolicy` startup ceiling, but the public App Server start API does not expose its `allowed_tools` field. The known configuration plus empty environments removes the dangerous local surfaces in source, but that is not evidence of the final model-visible request. Compatibility therefore remains disabled in normal app runs. `NGV_CODEX_APP_SERVER_ACCEPTANCE=1` is reserved for the dedicated approved Actions run.

That acceptance must capture the actual provider request and prove that the advertised tool surface contains only the intended `nexgen` namespace. A version or model that advertises any other callable capability is incompatible even if the sandbox would later deny execution.

This check cannot be replaced by configuration inspection. In the pinned [tool planner](https://github.com/openai/codex/blob/rust-v0.156.0/codex-rs/core/src/tools/spec_plan.rs), model catalog metadata can independently enable the built-in async-user-message and clock tools even when their feature flags are false. The adapter rejects every non-`item/tool/call` request and every non-`nexgen` namespace, but rejection after advertisement is not a sufficient isolation proof.

There is also a confirmed cold-resume incompatibility. In the pinned [`thread/resume` processor](https://github.com/openai/codex/blob/rust-v0.156.0/codex-rs/app-server/src/request_processors/thread_processor.rs), a cold thread is restored through `resume_thread_with_history`; the pinned [`ThreadManager`](https://github.com/openai/codex/blob/rust-v0.156.0/codex-rs/core/src/thread_manager.rs) then uses `StartThreadOptions::new`, which defaults `dynamic_tools` to empty and `environments` to `None`. That discards the host namespace and can reattach the default local environment. Passing empty `runtimeWorkspaceRoots`, read-only sandboxing, and current instructions does not restore the missing environment/tool selection. NexGenVideo therefore rejects cold/native resume before launching App Server and does not advertise `resumeNativeSession` for this backend. Multi-turn dialogue is supported only while the original bounded process and thread remain live.

This is a version incompatibility, not an acceptance item that can be waived. A later pinned CLI must expose a resume contract that reasserts both the dynamic-tool namespace and empty environment selection before the backend can become selectable. The Codex picker and durable backend preference remain out of scope and disabled.

## Required acceptance evidence

The approved Actions run must retain redacted evidence for:

1. exact CLI/package version, generated schema hashes, initialize/initialized, isolated `codexHome`, and strict-config success;
2. isolated account status and billing mode before any model or model-list request;
3. the actual model catalog and input modalities used by the later discovery contract;
4. complete model-visible tool inventory, including negative adversarial personal config fixtures;
5. text, actual image data, `nexgen` tool call/result with typed image output, dialog/spend suspension, and localized phase instructions;
6. two chats and projects, warm dialogue continuity, explicit cold-resume rejection, cancel/resend with a late old response, wrong runtime identity, EOF, timeout, crash, offline/auth expiry, unknown events, and reconnect/reinitialization joining the existing host phase job;
7. process-tree exit and absence of secrets, prompts, tokens, or raw tool payloads in Actions logs.

The real LLM smoke is a separately approved paid step. Normal CI covers only deterministic protocol/consumer fixtures.
