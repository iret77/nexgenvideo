# Private chat replay

`chat-replay.enc` contains owner-approved diagnostic inputs encrypted with
AES-256-GCM. The key is supplied only through the `NGV_CHAT_REPLAY_KEY` Actions
secret. Never commit plaintext inputs or keys.

The Chat Hang Replay workflow decrypts into runner temporary storage and replays
each saved session incrementally without executing its tool calls. It presents
recorded dialogs and verifies native text-input focus. Only the numeric
result summary and authenticated-encrypted diagnostics may be uploaded.
Screenshots are disabled for private sessions. `project-replay.enc` supplies the
timeline, media manifest and available pipeline metadata. The harness loads the
exact pinned released pack and checks phase counts and the next phase before
replaying. External media and unprovided phase artifacts remain absent.

Once the investigation no longer needs these inputs, remove both encrypted
fixtures, diagnostic artifacts, temporary plaintext copies and all replay-key
copies, including the Actions secret. Do not retain them as permanent test data.

This is a reproduction harness, not evidence that the hang is fixed.
