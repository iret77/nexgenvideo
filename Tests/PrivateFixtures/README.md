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

The control arm uses the current replay harness with the released transcript rendering
surface, isolating the production layout change from improvements to the replay itself.
It is accepted when it either finishes coherently or stalls inside the captured failure
window because the reported hang is timing-dependent. The candidate must always finish
every state with the recorded window geometry and a
responsive main-thread pulse. Chat Hang Replay uses generated content to stress
streaming, images, dialogs, resizing, scrolling, and composer focus without private
fixtures or secrets.
