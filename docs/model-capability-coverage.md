# Model capability coverage

Inventory date: `2026-08-31`. Stale threshold: `120 days`.
The report is generated offline from the checked-in corpus; web access is not part of CI.

## Summary

| Offers | Non-fixture | Exact | Inherited | Defensive | Stale | Conflicting | Research-needed | Unclassified |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 87 | 85 | 75 | 1 | 11 | 3 | 7 | 87 | 0 |

`exact` identifies a concrete intrinsic profile. `inherited` is an explicit family/variant lineage miss. `defensive` is used for unknown or deliberately unversioned IDs. Stale and conflicting evidence stays visible and forces research-needed.

## Defensive numeric defaults — owner confirmation pending

These values are explicit data, not inferred approval. Production activation remains blocked until the owner confirms or changes them.

| Field group | Pending value |
| --- | ---: |
| Reliable visible-character / primary reference count | 1 |
| Image outputs per request | 1 |
| Other integer counts | 0 |
| Minimum duration | 0 s |
| Maximum duration | 30 s |
| Boolean capabilities | false |
| Supported sets | empty |

## Coverage

| Modality | Provider | Provider model | Catalog model | Profile | Resolution | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
| audio | fal | `fal-ai/elevenlabs/sound-effects` | `fal-ai/elevenlabs/sound-effects` | `—` | defensive | research-needed |
| audio | fal | `fal-ai/elevenlabs/tts/multilingual-v2` | `fal-ai/elevenlabs/tts/multilingual-v2` | `elevenlabs/multilingual-tts/2` | exact | research-needed |
| audio | runway | `eleven_multilingual_sts_v2` | `runway/eleven_multilingual_sts_v2` | `elevenlabs/speech-to-speech/2` | exact | research-needed |
| audio | runway | `eleven_multilingual_v2` | `runway/eleven_multilingual_v2` | `elevenlabs/multilingual-tts/2` | exact | research-needed |
| audio | runway | `eleven_text_to_sound_v2` | `runway/eleven_text_to_sound_v2` | `elevenlabs/text-to-sound/2` | exact | research-needed |
| audio | runway | `eleven_v3` | `runway/eleven_v3` | `elevenlabs/tts/3` | exact | research-needed |
| audio | runway | `eleven_voice_dubbing` | `runway/eleven_voice_dubbing` | `—` | defensive | research-needed |
| audio | runway | `eleven_voice_isolation` | `runway/eleven_voice_isolation` | `—` | defensive | research-needed |
| audio | runway | `seed_audio` | `runway/seed_audio` | `seed-audio/multimodal/1.0` | exact | research-needed |
| image | fal | `fal-ai/clarity-upscaler` | `fal-ai/clarity-upscaler` | `—` | defensive | research-needed |
| image | fal | `fal-ai/flux-pro/kontext` | `fal-ai/flux-pro/kontext` | `flux-kontext/pro/1` | exact | research-needed |
| image | fal | `fal-ai/flux-pro/v1.1` | `fal-ai/flux-pro/v1.1` | `flux-pro/standard/1.1` | exact | research-needed |
| image | fal | `fal-ai/flux-pro/v1.1-ultra` | `fal-ai/flux-pro/v1.1-ultra` | `flux-pro/ultra/1.1` | exact | research-needed |
| image | fal | `fal-ai/flux/dev` | `fal-ai/flux/dev` | `flux/dev/1` | exact | research-needed |
| image | fal | `fal-ai/flux/schnell` | `fal-ai/flux/schnell` | `flux/schnell/1` | exact | research-needed |
| image | fal | `fal-ai/nano-banana/edit` | `fal-ai/gemini-25-flash-image/edit` | `gemini-image/unified/2.5-flash` | exact | research-needed |
| image | google | `gemini-2.5-flash-image` | `fal-ai/gemini-25-flash-image/edit` | `gemini-image/unified/2.5-flash` | exact | research-needed |
| image | fal | `fal-ai/gpt-image-2` | `fal-ai/gpt-image-2` | `gpt-image/unified/2` | exact | research-needed |
| image | fal | `openai/gpt-image-2/edit` | `fal-ai/gpt-image-2/edit` | `gpt-image/unified/2` | exact | research-needed |
| image | fal | `fal-ai/ideogram/v3` | `fal-ai/ideogram/v3` | `ideogram/text-to-image/3` | exact | research-needed |
| image | fal | `fal-ai/imagen4` | `fal-ai/imagen4` | `imagen/text-to-image/4` | exact | stale, research-needed |
| image | fal | `fal-ai/nano-banana` | `fal-ai/nano-banana` | `gemini-image/unified/2.5-flash` | exact | research-needed |
| image | fal | `fal-ai/nano-banana-2` | `fal-ai/nano-banana-2` | `gemini-image/unified/3.1-flash` | exact | research-needed |
| image | fal | `fal-ai/nano-banana-2/edit` | `fal-ai/nano-banana-2/edit` | `gemini-image/unified/3.1-flash` | exact | research-needed |
| image | fal | `fal-ai/nano-banana-pro` | `fal-ai/nano-banana-pro` | `gemini-image/unified/3-pro` | exact | research-needed |
| image | fal | `fal-ai/nano-banana-pro/edit` | `fal-ai/nano-banana-pro/edit` | `gemini-image/unified/3-pro` | exact | research-needed |
| image | fal | `fal-ai/qwen-image` | `fal-ai/qwen-image` | `—` | defensive | research-needed |
| image | fal | `fal-ai/recraft/v3/text-to-image` | `fal-ai/recraft/v3/text-to-image` | `recraft/text-to-image/3` | exact | research-needed |
| image | fal | `fal-ai/stable-diffusion-v35-large` | `fal-ai/stable-diffusion-v35-large` | `stable-diffusion/large/3.5` | exact | research-needed |
| image | google | `gemini-3-pro-image` | `google/gemini-3-pro-image` | `gemini-image/unified/3-pro` | exact | research-needed |
| image | google | `gemini-3-pro-image-preview` | `google/gemini-3-pro-image` | `gemini-image/unified/3-pro` | exact | stale, research-needed |
| image | google | `gemini-3.1-flash-image` | `google/gemini-3.1-flash-image` | `gemini-image/unified/3.1-flash` | exact | research-needed |
| image | google | `gemini-3.1-flash-image-preview` | `google/gemini-3.1-flash-image` | `gemini-image/unified/3.1-flash` | exact | stale, research-needed |
| image | google | `gemini-3.1-flash-lite-image` | `google/gemini-3.1-flash-lite-image` | `gemini-image/unified/3.1-flash-lite` | exact | research-needed |
| image | marble | `marble-1.0` | `marble/marble-1.0` | `marble/standard/1.0` | exact | research-needed |
| image | marble | `marble-1.0-draft` | `marble/marble-1.0-draft` | `marble/draft/1.0` | exact | research-needed |
| image | marble | `marble-1.1` | `marble/marble-1.1` | `marble/standard/1.1` | exact | research-needed |
| image | marble | `marble-1.1-plus` | `marble/marble-1.1-plus` | `marble/plus/1.1` | exact | research-needed |
| image | runway | `gemini_2.5_flash` | `runway/gemini_2.5_flash` | `gemini-image/unified/2.5-flash` | exact | research-needed |
| image | runway | `gemini_image3.1_flash` | `runway/gemini_image3.1_flash` | `gemini-image/unified/3.1-flash` | exact | research-needed |
| image | runway | `gemini_image3_pro` | `runway/gemini_image3_pro` | `gemini-image/unified/3-pro` | exact | research-needed |
| image | runway | `gen4_image` | `runway/gen4_image` | `runway-gen-image/standard/4` | exact | research-needed |
| image | runway | `gen4_image_turbo` | `runway/gen4_image_turbo` | `runway-gen-image/turbo/4` | exact | research-needed |
| image | runway | `gpt_image_2` | `runway/gpt_image_2` | `gpt-image/unified/2` | exact | research-needed |
| image | runway | `grok_imagine_image_2` | `runway/grok_imagine_image_2` | `grok-imagine-image/standard/2` | exact | research-needed |
| image | runway | `magnific_precision_upscaler_v2` | `runway/magnific_precision_upscaler_v2` | `magnific/image-upscale/2` | exact | research-needed |
| image | runway | `muse_image` | `runway/muse_image` | `muse-image/standard/1` | exact | research-needed |
| image | runway | `seedream5_lite` | `runway/seedream5_lite` | `seedream/lite/5` | exact | research-needed |
| image | runway | `seedream5_pro` | `runway/seedream5_pro` | `seedream/pro/5` | exact | research-needed |
| music | fal | `fal-ai/elevenlabs/music` | `fal-ai/elevenlabs/music` | `—` | defensive | research-needed |
| music | fal | `fal-ai/stable-audio` | `fal-ai/stable-audio` | `—` | defensive | research-needed |
| video | fal | `bytedance/seedance-2.0/image-to-video` | `bytedance/seedance-2.0/image-to-video` | `seedance/image-to-video/2.0` | exact | research-needed |
| video | fal | `bytedance/seedance-2.0/reference-to-video` | `bytedance/seedance-2.0/reference-to-video` | `seedance/reference-to-video/2.0` | exact | research-needed |
| video | fal | `bytedance/seedance-2.0/text-to-video` | `bytedance/seedance-2.0/text-to-video` | `seedance/text-to-video/2.0` | exact | research-needed |
| video | fal | `bytedance/seedance-2.5/image-to-video` | `bytedance/seedance-2.5/image-to-video` | `seedance/image-to-video/2.5` | exact | conflict, research-needed |
| video | fal | `bytedance/seedance-2.5/reference-to-video` | `bytedance/seedance-2.5/reference-to-video` | `seedance/reference-to-video/2.5` | exact | conflict, research-needed |
| video | fal | `bytedance/seedance-2.5/text-to-video` | `bytedance/seedance-2.5/text-to-video` | `seedance/text-to-video/2.5` | exact | conflict, research-needed |
| video | fal | `fal-ai/bytedance/seedance/v1/pro/image-to-video` | `fal-ai/bytedance/seedance/v1/pro/image-to-video` | `seedance/image-to-video/1.0` | exact | research-needed |
| video | fal | `fal-ai/bytedance/seedance/v1/pro/text-to-video` | `fal-ai/bytedance/seedance/v1/pro/text-to-video` | `seedance/text-to-video/1.0` | exact | research-needed |
| video | fal | `fal-ai/kling-video/v2.5-turbo/pro/image-to-video` | `fal-ai/kling-video/v2.5-turbo/pro/image-to-video` | `kling/image-to-video/2.5-turbo-pro` | exact | research-needed |
| video | fal | `fal-ai/kling-video/v2.5-turbo/pro/text-to-video` | `fal-ai/kling-video/v2.5-turbo/pro/text-to-video` | `kling/text-to-video/2.5-turbo-pro` | exact | research-needed |
| video | fal | `fal-ai/minimax/hailuo-02/standard/text-to-video` | `fal-ai/minimax/hailuo-02/standard/text-to-video` | `hailuo/text-to-video-standard/2.0` | exact | research-needed |
| video | fal | `fal-ai/topaz/upscale/video` | `fal-ai/topaz/upscale/video` | `—` | defensive | research-needed |
| video | fal | `fal-ai/veo3` | `fal-ai/veo3` | `veo/text-to-video/3` | exact | research-needed |
| video | fal | `minimax/h3/image-to-video` | `minimax/h3/image-to-video` | `minimax-h3/fl2va/3` | exact | conflict, research-needed |
| video | fal | `minimax/h3/reference-to-video` | `minimax/h3/reference-to-video` | `minimax-h3/ref2va/3` | exact | conflict, research-needed |
| video | fal | `minimax/h3/text-to-video` | `minimax/h3/text-to-video` | `minimax-h3/fl2va/3` | exact | conflict, research-needed |
| video | runway | `act_two` | `runway/act_two` | `runway-act/performance-capture/2` | exact | research-needed |
| video | runway | `aleph2` | `runway/aleph2` | `runway-aleph/video-edit/2` | exact | research-needed |
| video | runway | `gemini_omni_flash` | `runway/gemini_omni_flash` | `gemini-omni/flash/1` | exact | research-needed |
| video | runway | `gen4.5` | `runway/gen4.5` | `runway-gen/image-to-video/4.5` | exact | research-needed |
| video | runway | `gen4_turbo` | `runway/gen4_turbo` | `runway-gen/image-to-video-turbo/4` | exact | research-needed |
| video | runway | `grok_imagine_1_5` | `runway/grok_imagine_1_5` | `grok-imagine-video/standard/1.5` | exact | research-needed |
| video | runway | `gwm1_avatars` | `runway/gwm1_avatars` | `runway-gwm/avatars/1` | exact | research-needed |
| video | runway | `hailuo3` | `runway/hailuo3` | `minimax-h3/ref2va/3` | exact | conflict, research-needed |
| video | runway | `happyhorse_1_0` | `runway/happyhorse_1_0` | `happyhorse/multimodal/1.0` | exact | research-needed |
| video | runway | `magnific_video_upscaler_creative` | `runway/magnific_video_upscaler_creative` | `—` | defensive | research-needed |
| video | runway | `ruby` | `runway/ruby` | `—` | defensive | research-needed |
| video | runway | `seedance2` | `runway/seedance2` | `seedance/multimodal/2.0` | exact | research-needed |
| video | runway | `seedance2_5` | `runway/seedance2_5` | `seedance/multimodal/2.5` | exact | research-needed |
| video | runway | `seedance2_fast` | `runway/seedance2_fast` | `seedance/multimodal-fast/2.0` | exact | research-needed |
| video | runway | `seedance2_mini` | `runway/seedance2_mini` | `seedance/multimodal-mini/2.0` | exact | research-needed |
| video | runway | `veo3.1` | `runway/veo3.1` | `veo/multimodal/3.1` | exact | research-needed |
| video | runway | `veo3.1_fast` | `runway/veo3.1_fast` | `veo/multimodal-fast/3.1` | exact | research-needed |
| video | runway | `wan3` | `runway/wan3` | `wan/multimodal/3` | exact | research-needed |
| video | fixture | `hupfntrupfn` | `fixture/hupfntrupfn` | `—` | defensive | research-needed |
| video | fixture | `seedance-3.0-reference` | `fixture/seedance-3.0/reference-to-video` | `seedance/reference-to-video/3.0` | inherited | research-needed |

## Primary sources

- [fal MiniMax H3 live endpoint schema](https://api.fal.ai/v1/models?endpoint_id=minimax%2Fh3%2Freference-to-video&expand=openapi-3.0) — Free live OpenAPI lookup; no generation call.
- [fal MiniMax H3 endpoint documentation](https://fal.ai/models/minimax/h3/reference-to-video) — Provider-published prompt guidance for MiniMax H3 reference-to-video.
- [fal Model Search API and endpoint OpenAPI schemas](https://fal.ai/docs/platform-apis/v1/models) — Free endpoint-id and OpenAPI lookups for the shipped fal registry plus MiniMax H3; no generation calls.
- [fal Seedance 2.5 endpoint documentation](https://fal.ai/models/bytedance/seedance-2.5/reference-to-video) — Text, image and reference modes; reference counts and duration/resolution contracts.
- [fal Seedance 2.5 production guidance](https://fal.ai/learn/devs/how-to-use-seedance-2-5) — Provider-published reliable subject/reference guidance, kept separate from hard API limits.
- [fal endpoint metadata: bytedance/seedance-2.0/image-to-video](https://api.fal.ai/v1/models?endpoint_id=bytedance%2Fseedance-2.0%2Fimage-to-video) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: bytedance/seedance-2.0/reference-to-video](https://api.fal.ai/v1/models?endpoint_id=bytedance%2Fseedance-2.0%2Freference-to-video) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: bytedance/seedance-2.0/text-to-video](https://api.fal.ai/v1/models?endpoint_id=bytedance%2Fseedance-2.0%2Ftext-to-video) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: bytedance/seedance-2.5/image-to-video](https://api.fal.ai/v1/models?endpoint_id=bytedance%2Fseedance-2.5%2Fimage-to-video) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: bytedance/seedance-2.5/reference-to-video](https://api.fal.ai/v1/models?endpoint_id=bytedance%2Fseedance-2.5%2Freference-to-video) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: bytedance/seedance-2.5/text-to-video](https://api.fal.ai/v1/models?endpoint_id=bytedance%2Fseedance-2.5%2Ftext-to-video) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/bytedance/seedance/v1/pro/image-to-video](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fbytedance%2Fseedance%2Fv1%2Fpro%2Fimage-to-video) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/bytedance/seedance/v1/pro/text-to-video](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fbytedance%2Fseedance%2Fv1%2Fpro%2Ftext-to-video) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/clarity-upscaler](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fclarity-upscaler) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/elevenlabs/music](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Felevenlabs%2Fmusic) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/elevenlabs/sound-effects](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Felevenlabs%2Fsound-effects) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/elevenlabs/tts/multilingual-v2](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Felevenlabs%2Ftts%2Fmultilingual-v2) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/flux-pro/kontext](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fflux-pro%2Fkontext) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/flux-pro/v1.1](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fflux-pro%2Fv1.1) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/flux-pro/v1.1-ultra](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fflux-pro%2Fv1.1-ultra) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/flux/dev](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fflux%2Fdev) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/flux/schnell](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fflux%2Fschnell) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/gpt-image-2](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fgpt-image-2) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/ideogram/v3](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fideogram%2Fv3) — Free endpoint metadata lookup; no generation call.
- [fal endpoint lookup result: fal-ai/imagen4](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fimagen4) — Free endpoint metadata lookup returned HTTP 404; no generation call.
- [fal endpoint metadata: fal-ai/kling-video/v2.5-turbo/pro/image-to-video](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fkling-video%2Fv2.5-turbo%2Fpro%2Fimage-to-video) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/kling-video/v2.5-turbo/pro/text-to-video](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fkling-video%2Fv2.5-turbo%2Fpro%2Ftext-to-video) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/minimax/hailuo-02/standard/text-to-video](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fminimax%2Fhailuo-02%2Fstandard%2Ftext-to-video) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/nano-banana](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fnano-banana) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/nano-banana-2](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fnano-banana-2) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/nano-banana-2/edit](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fnano-banana-2%2Fedit) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/nano-banana-pro](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fnano-banana-pro) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/nano-banana-pro/edit](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fnano-banana-pro%2Fedit) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/nano-banana/edit](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fnano-banana%2Fedit) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/qwen-image](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fqwen-image) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/recraft/v3/text-to-image](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Frecraft%2Fv3%2Ftext-to-image) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/stable-audio](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fstable-audio) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/stable-diffusion-v35-large](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fstable-diffusion-v35-large) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/topaz/upscale/video](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Ftopaz%2Fupscale%2Fvideo) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: fal-ai/veo3](https://api.fal.ai/v1/models?endpoint_id=fal-ai%2Fveo3) — Free endpoint metadata lookup; no generation call.
- [fal endpoint metadata: openai/gpt-image-2/edit](https://api.fal.ai/v1/models?endpoint_id=openai%2Fgpt-image-2%2Fedit) — Free endpoint metadata lookup; no generation call.
- [Google Gemini model deprecations](https://ai.google.dev/gemini-api/docs/deprecations) — Stable and retired Gemini image aliases.
- [Google Gemini image generation documentation](https://ai.google.dev/gemini-api/docs/image-generation) — Gemini image IDs, reference/identity capacity, resolutions and aspect ratios.
- [MiniMax H3 open model specification](https://www.minimax.io/news/minimax-h3-open-source) — Creator specification for FL2VA and Ref2VA, durations, FPS, audio and multimodal references.
- [Runway Dev API changelog](https://docs.dev.runwayml.com/api-details/api_changelog/) — Version-specific limits for newly added Runway models.
- [Runway Dev available models](https://docs.dev.runwayml.com/guides/models/) — Complete public Runway model inventory at the inventory date.
- [World Labs API model inventory](https://docs.worldlabs.ai/api/models) — Complete public Marble model inventory at the inventory date.

## Unresolved inventory access

- **higgsfield** — The effective catalog is available only through the user's authenticated MCP session; no unauthenticated list endpoint was found.
- **openart** — The effective catalog is available only through the user's authenticated MCP session; no unauthenticated list endpoint was found.

## Evidence gaps

Unknown numeric values remain null and resolve defensively; they are not estimated. The machine-readable `profile_gaps` map in the corpus lists every field-level gap. Notably, MiniMax H3 publishes high multimodal reference capacity but no numeric reliable on-screen figure capacity.
