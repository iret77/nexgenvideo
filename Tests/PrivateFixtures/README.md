# Encrypted hang reproduction

The temporary hang fixture is authenticated AES-256-GCM ciphertext. Its outer
key is supplied through the `NGV_HANG_FIXTURE_KEY_890AD793` Actions secret. The
original recording key is inside the encrypted fixture. Neither key nor plaintext
belongs in source control or public logs, screenshots or artifacts.

The replay runs the shipped application without executing recorded tool calls.
Only numerical results and authenticated-encrypted diagnostic output are uploaded.
Private logs, stack samples and a final window image exist only in temporary storage
and inside the encrypted diagnostic archive.
A completed replay with different window/scroll geometry does not prove a fix.
Remove the temporary fixture and its secret when investigation is complete.

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

Recorded Hang Replay passes only when the released control stalls inside the captured
failure window and the candidate finishes every state with a responsive main-thread
pulse. Chat Hang Replay remains broader regression coverage for saved sessions.
