# Encrypted hang reproduction

The temporary hang fixture is authenticated AES-256-GCM ciphertext. Its outer
key is supplied through the `NGV_HANG_FIXTURE_KEY` Actions secret. The original
recording key is inside the encrypted fixture. Neither key nor plaintext belongs
in source control or public logs, screenshots or artifacts.

The replay runs the shipped application without executing recorded tool calls.
Only numerical results and authenticated-encrypted diagnostic output are uploaded.
Private logs, stack samples and a final window image exist only in temporary storage
and inside the encrypted diagnostic archive.
A completed replay with different window/scroll geometry does not prove a fix.
Remove the temporary fixture and its secret when investigation is complete.
