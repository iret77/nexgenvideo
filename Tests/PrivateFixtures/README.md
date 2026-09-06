# Private chat replay

`chat-replay.enc` contains owner-approved diagnostic inputs encrypted with
AES-256-GCM. The key is supplied only through the `NGV_CHAT_REPLAY_KEY` Actions
secret. Never commit plaintext inputs or keys.

The Chat Hang Replay workflow decrypts into runner temporary storage and loads
the latest saved session without executing its tool calls. Only the numeric
result summary and authenticated-encrypted diagnostics may be uploaded.
Screenshots are disabled for private sessions. The project metadata is retained
in the encrypted input but is not a substitute for opening the complete project.

This is a reproduction harness, not evidence that the hang is fixed.
