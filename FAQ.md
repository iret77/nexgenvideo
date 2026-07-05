# FAQ

**What is NexGenVideo?**

An open-source, AI-native video editor for macOS. You and your agent work on the same timeline: the agent scripts, generates, and edits through the same tool layer you use. NexGenVideo is a fork of Palmier Pro, continued as an autonomous project — no accounts, no hosted backend.

**Is it free?**

The editor is free and open source (GPLv3). Generative features use your own provider API keys (fal.ai, Runway, ElevenLabs, Marble) — you pay those providers directly, only for what you generate. The in-app agent runs on your Anthropic API key, or through Claude Code on your Claude subscription.

**How does the AI integration work?**

Three surfaces:

1. **In-app agent** — chat with `@`-references to your media, driving the timeline through the editor's tools.
2. **MCP server** — while the app is open it serves MCP at `http://127.0.0.1:19789/mcp`; connect Claude Code, Claude Desktop, Cursor, or Codex and drive the editor from outside.
3. **Format plugins** — packs like `musicvideo` add structured production workflows (analysis → treatment → storyboard → shotlist → render) on top of the editor.

**Which generation models are supported?**

The catalog is curated in code: image (FLUX family, Recraft, Ideogram, Imagen, Runway Gen-4 Image, …), video (Kling, Seedance, Veo, Runway Gen-4.5, …), audio (ElevenLabs TTS/SFX/Music, Stable Audio), upscaling (Clarity, Topaz), and 3D worlds (Marble). A model is available once its provider's key is set in Settings → Providers.

**Do I need an account?**

No. There is no login and no hosted service. Keys live in your macOS Keychain; projects are local `.ngv` packages.

**What platforms does it support?**

macOS 26 (Tahoe) on Apple Silicon.
