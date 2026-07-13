# Chord recognition model — selection, license, input contract

Step 0 of [#192](https://github.com/iret77/nexgenvideo/issues/192) (device-gated remainder of #191).
This is the locked decision the rest of the chord work builds on. **Do not re-litigate it without a
concrete reason** — everything downstream (the CQT frontend, the ONNX provider) is mechanical once
the model is fixed, and it is fixed here.

## Decision: BTC (Bi-directional Transformer for Chord recognition)

- Repo: [`jayg996/BTC-ISMIR19`](https://github.com/jayg996/BTC-ISMIR19), paper *A Bi-Directional
  Transformer for Musical Chord Recognition* (ISMIR 2019).
- **License: MIT** (`Copyright (c) 2019 Jonggwon Park`) — bundling, redistribution, modification and
  **commercial use** are all permitted. This clears the acceptance rule that a permissive license
  must allow bundling *or* commercial runtime download; MIT allows both.
- **Pretrained weights ship in the repo under the same MIT license** — no separate weights license to
  vet, unlike madmom (whose trained models are CC BY-NC-SA and therefore unusable in a Developer-ID
  commercial app; that is why the reference *mechanism* was ported but the *weights* had to change):
  - `test/btc_model.pt` — maj/min vocabulary (25 classes).
  - `test/btc_model_large_voca.pt` — large vocabulary (170 classes).
- Runs on CPU via onnxruntime in seconds for a 3–4 min track (8-layer transformer, hidden size 128).

### Vocabulary choice

Ship the **maj/min (25-class)** model as the default: 12 major + 12 minor + `N` (no-chord). It is the
faithful analogue of the reference pipeline's output and the label set our schema and the Python
`chord_progression` (which dropped `"N"`) already expect. The 170-class large-voca model is a drop-in
alternative (same architecture, different `output_layer` width + vocabulary) if richer labels are
wanted later — the `chord_progression` schema field is a free string, so it accommodates either.

## Input contract (derived from the preprocessing SOURCE, not docs)

All values from `run_config.yaml` and `utils/mir_eval_modules.py::audio_file_to_features` /
`test.py` in the repo — reconcile the Swift frontend against *these*, per the Beat This! lesson
(`mel_scale="slaney"` vs `norm='slaney'`): match the model's actual preprocessing code, never its prose.

| Stage | Value | Source |
|---|---|---|
| Sample rate | 22050 Hz, mono | `run_config.mp3.song_hz`; `librosa.load(..., sr, mono=True)` |
| Segment length | 10.0 s windows, CQT'd independently then concatenated on the time axis | `mp3.inst_len`; the `while` loop in `audio_file_to_features` |
| Transform | `librosa.cqt(y, sr=22050, n_bins=144, bins_per_octave=24, hop_length=2048)` | `feature.n_bins/bins_per_octave/hop_length` |
| CQT defaults (implicit) | `fmin = C1 ≈ 32.703 Hz`, `tuning` estimated from signal, `filter_scale=1`, `norm=1`, `sparsity=0.01` | librosa defaults — **pin these explicitly in the Swift port**; librosa estimates tuning by default, a real fidelity trap |
| Magnitude | `feature = log(abs(CQT) + 1e-6)` | `audio_file_to_features` |
| Layout | transpose to `[T, 144]` | `test.py:56` `feature = feature.T` |
| **Normalization** | `feature = (feature - mean) / std`, where **`mean` and `std` are scalars stored in the checkpoint** (`checkpoint['mean']`, `checkpoint['std']`) | `test.py:40-41,57` — must be exported alongside the ONNX |
| Instancing | pad `T` up to a multiple of `timestep = 108`, then feed the transformer 108 frames at a time | `test.py:59-71`, `model.timestep` |
| Frame period | `time_unit = inst_len / timestep = 10 / 108 ≈ 0.092593 s` | `test.py:58` (`feature_per_second`) |
| Output | per-frame arg-max over the 25 (or 170) classes → chord index | `test.py:71-73` |
| Labels | `idx2chord` (25) / `idx2voca_chord` (170) index→label maps | `utils/mir_eval_modules.py` |

A 10 s window at hop 2048 / 22050 Hz yields ⌈220500/2048⌉ = 108 CQT frames, so `timestep = 108`
lines up with one segment exactly.

## How this maps onto NexGenVideo

The seam and the decode tail already landed (commit `dee95fe`, #191 steps 2–3) and are faithful to
BTC's own decode:

- **`ChordDecode.segments(labels:vocabulary:hopSeconds:)`** already does BTC's exact post-processing:
  per-frame arg-max indices → merge consecutive equal labels → `[start, end)` with
  `start = runStart·time_unit`, `end = runEnd⁺¹·time_unit`, drop `N`. Call it with
  `hopSeconds = 10.0/108.0`. BTC's transformer output is already temporally smooth, so `viterbi` is
  **optional** here (use it only as a light anti-flicker pass; `transitionPenalty = 0` reproduces raw
  arg-max).
- **`AudioChordRecognizing` / `RecognizedChord`** is the provider seam; `EngineRegistry.chordRecognizer`
  is wired into the analysis phase.

What remains (this doc + the export script make it mechanical):

1. **Model artifact** — run `scripts/export_btc_chord_onnx.py` (see its header) to produce
   `btc_chord.onnx` + `btc_chord_meta.json` (`{mean, std, vocabulary, timestep, ...}`) from the MIT
   checkpoint. Host it the way `beat_this.onnx` / `htdemucs` are (raw URL → `HFModelStore.ensure`).
2. **CQT frontend** — implement the CQT above in Swift/Accelerate (the DSP layer has STFT+mel but no
   CQT). **Validate against a librosa golden fixture before enabling** — a plausible-but-wrong CQT
   silently degrades chords, exactly the failure mode the on-device beat frontend guards against.
3. **`ChordRecognizer` provider** — mirror `BeatThisDetector`: `HFModelStore.ensure` the model, compute
   the frontend, apply `(x-mean)/std`, run `OrtRuntime` over 108-frame instances, arg-max, then
   `ChordDecode.segments(...)`. Register via `registry.registerChordRecognizer(...)`. Like
   `BeatThisDetector`, it **validates on-device** — return `nil` on an implausible result so the
   analysis keeps an empty (never wrong) chord progression.

Steps 2–3 are device/model-gated: they need the exported model and on-device inference to validate
fidelity, and cannot be verified in a headless CI-only environment (no `librosa`/`torch` to generate a
golden or run inference). They belong on a build the owner triggers with the model in hand — the same
loop `BeatThisDetector` went through.
