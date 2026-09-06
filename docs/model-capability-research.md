# Model capability research subsystem

This subsystem resolves issue #436 without widening the normal agent runtime. It is host-owned and
project-independent. The Models settings surface starts research explicitly, presents the verified
field diff, and applies only the fields the user accepts.

## Boundaries

- Research identity is exact: family, variant, version, modality, provider, offering, endpoint,
  catalog model, mode, and intrinsic/endpoint scope.
- Research accepts only official domains supplied by the host and covered by the built-in trusted
  provider and model-owner domain registry. Aggregated offerings may use both authorities for their
  exact bound family during intrinsic research; endpoint research remains provider-authoritative.
  `WebSearch` must use `allowed_domains`; `WebFetch` is rejected unless its URL is public HTTPS on
  one of those domains.
- Fetched text is never persisted. It is treated as untrusted evidence and cannot add tools,
  change scope, or become a prompt instruction.
- The result schema enumerates registered capability fields for the requested modality and closes
  every object with `additionalProperties: false`.
- The result validator rejects a changed identity, unknown or mistyped field, defensive or automated
  empirical claim, non-public/local/credential-bearing URL, control text, and instruction-like
  conflict text.
- No provider generation client, project path, provider credential, normal NexGenVideo MCP server,
  plugin, file tool, or shell tool enters the research process.

## Claude transport proof

The supported backend path is a separate Claude Code process. It does not reuse
`ClaudeCodeLaunch.arguments` or alter the normal chat process.
It uses the installed CLI's signed-in keychain session; OAuth/API-key environment fallback and every
generation-provider credential are removed from the child environment.

1. A non-model probe executes the selected binary with `--version` and `--help`. It requires the
   installed executable to advertise every isolation, tool-selection, and structured-output flag.
2. The research launch uses safe and restricted modes, an empty strict MCP configuration, a custom
   system prompt, no session persistence, a closed JSON schema, a cost ceiling, an isolated empty
   working directory, no user settings source, and exactly `WebSearch,WebFetch` in both the built-in
   tool set and allowlist.
3. The runtime `system/init` event must report exactly those two tools, no MCP servers, and the exact
   isolated directory. No candidate or subsequent tool event is accepted before this handshake.
4. Every emitted tool call and matching tool result is inspected. Search must be domain-scoped,
   fetch must pass the same public-URL policy, and evidence is accepted only from a fetch whose
   runtime result completed successfully.
5. Time and output-byte ceilings terminate a stuck or unbounded process. The session cannot resume.

The tool names and CLI semantics are grounded in Anthropic's primary documentation:

- [Claude Code tools reference](https://code.claude.com/docs/en/tools-reference)
- [Claude Agent SDK tool and permission contract](https://code.claude.com/docs/en/agent-sdk/agent-loop)
- [Claude Code CLI reference](https://docs.anthropic.com/en/docs/claude-code/cli-usage)

## Local storage

The default file is:

`~/Library/Application Support/NexGenVideo/ModelCapabilityResearch/overlays-v1.json`

The store is a versioned, atomically replaced JSON document. It is rejected under any `.ngv` path.
Each record contains only:

- record ID, status, acceptance date, and optional superseded-record ID;
- exact binding and intrinsic/endpoint scope;
- accepted capability fields with per-field evidence; and
- the official source-host allowlist needed to revalidate persisted evidence.

There is no representable field for API keys, raw research prompts, fetched page bodies, project
paths, or media. V0 documents migrate to V1 on load. Corrupt, unknown, or future schemas fail closed;
they are not silently reset. Accept marks the prior active record for the same canonical key as
superseded. Explicitly disabled or archived records stay that way; deleting an active replacement
restores only the record it superseded, never one the user explicitly disabled or archived.

## Fieldwise resolution

Resolution never replaces the bundled corpus. It produces a sidecar effective profile and a decision
for every local field.

| Condition | Effective value |
|---|---|
| Local evidence contains a conflict | Existing safe fallback |
| Local evidence is inferred-only or below proof threshold | Existing safe fallback |
| Exact curated evidence has equal/higher authority and is at least as fresh | Curated value |
| Accepted evidence is stronger/newer than inherited, defensive, or older curated evidence | Accepted local value |
| Current live endpoint schema is stricter | Endpoint-bounded value |
| Endpoint-scoped record has no exact offering and mode match | Existing safe fallback |

Authority order is provider schema, documented API, separately approved empirical evidence, inferred,
then defensive. Authority, observation date, and confidence are compared in that order. Staleness is
reported and re-offers research; it does not erase the best accepted evidence by itself. A newer
authoritative curated value can supersede a local field without deleting the local audit record.

## Offline verification

Checked-in fixtures cover image, video, and music capabilities plus a recorded Claude CLI help/init
contract. CI tests use only those fixtures. They perform no web request, catalog mutation, provider
request, generation, or deliberately invalid probe. The visual contract is normative in
[`docs/ui/model-capability-research.html`](ui/model-capability-research.html), and the native SwiftUI
implementation follows that contract in Models settings.
