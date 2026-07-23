# FAQ

**What is NexGenVideo?**

An open-source, AI-native video editor for macOS. You and your agent work on the same timeline: the agent scripts, generates, and edits through the same tool layer you use. NexGenVideo is a fork of Palmier Pro, continued as an autonomous project — no accounts, no hosted backend.

**Is it free?**

The editor is free and open source (GPLv3). Generative features use your own provider API keys (fal.ai, Runway, ElevenLabs, Marble) — you pay those providers directly, only for what you generate. The in-app agent normally runs through Claude Code on your Claude subscription; direct use with your own Anthropic API key is also supported.

**How does the AI integration work?**

Three surfaces:

1. **In-app agent** — chat with `@`-references to your media, driving the timeline through the editor's tools.
2. **MCP server** — while the app is open it serves MCP at `http://127.0.0.1:19789/mcp`; connect Claude Code, Claude Desktop, Cursor, or Codex and drive the editor from outside.
3. **Format plugins** — packs like `musicvideo` add structured production workflows (analysis → treatment → storyboard → shotlist → render) on top of the editor.

**Which generation models are supported?**

The catalog covers image, video, audio, upscaling, and 3D-world models. It shows only models available through providers you activated in Settings → Providers, whether by API key, sign-in, or MCP.

**Do I need an account?**

No. There is no login and no hosted service. Keys live in your macOS Keychain; projects are local `.ngv` packages.

**What platforms does it support?**

macOS 26 (Tahoe) on Apple Silicon.
