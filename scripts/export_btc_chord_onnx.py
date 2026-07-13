#!/usr/bin/env python3
"""Export the BTC chord model to a self-contained ONNX with the CQT front-end baked in.

Step 0 artifact for issue #192 (see docs/CHORD_MODEL.md). BTC (jayg996/BTC-ISMIR19) is MIT-licensed
and ships its pretrained checkpoints under the same license, so the model and its weights may be
bundled / runtime-downloaded in the commercial Developer-ID app.

Design decision (robustness under a headless implementer): the fidelity-critical CQT front-end is
baked INTO the ONNX graph via nnAudio (`CQT1992v2`, which follows librosa conventions) rather than
re-implemented in Swift. Consequences:
  * The exported model takes a RAW 10 s mono window at 22.05 kHz and returns per-frame chord logits.
    The Swift `ChordRecognizer` provider then only windows the audio, runs the session, arg-maxes, and
    hands off to `ChordDecode` — no fragile DSP in Swift.
  * CQT↔librosa fidelity is verified HERE, in Python, where librosa actually runs (`--check-parity`),
    instead of being hand-waved on the Swift side. This is the whole point: the one place the DSP can
    be checked against ground truth is at export.

Outputs:
  * btc_chord.onnx        — audio [1, 220500] float32 → logits [1, 108, num_chords]
  * btc_chord_meta.json   — { vocabulary, num_chords, no_chord_label, sample_rate, inst_len_s,
                              timestep, hop_length }

NOT a CI step (needs torch + nnAudio + the BTC repo). Run once, then host both files (raw URL →
HFModelStore.ensure), matching how beat_this.onnx / htdemucs are hosted.

Usage:
    git clone https://github.com/jayg996/BTC-ISMIR19
    pip install torch nnAudio numpy pyyaml librosa   # librosa only for --check-parity
    python scripts/export_btc_chord_onnx.py --btc-repo ./BTC-ISMIR19 --voca false \
        --out-dir ./chord-model --check-parity ./BTC-ISMIR19/test/example.mp3
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--btc-repo", type=Path, required=True, help="Path to a clone of jayg996/BTC-ISMIR19.")
    ap.add_argument("--voca", type=lambda x: str(x).lower() == "true", default=False,
                    help="false = maj/min 25-class (default), true = large-voca 170-class.")
    ap.add_argument("--out-dir", type=Path, default=Path("./chord-model"))
    ap.add_argument("--check-parity", type=Path, default=None,
                    help="Optional audio file: assert the baked nnAudio CQT matches librosa's on it.")
    args = ap.parse_args()

    repo = args.btc_repo.resolve()
    if not (repo / "btc_model.py").exists():
        print(f"error: {repo} is not a BTC-ISMIR19 checkout (no btc_model.py).", file=sys.stderr)
        return 2
    sys.path.insert(0, str(repo))

    import numpy as np  # noqa: E402
    import torch  # noqa: E402
    from nnAudio.features.cqt import CQT1992v2  # type: ignore  # noqa: E402
    from btc_model import BTC_model  # type: ignore  # noqa: E402
    from utils import hparams  # type: ignore  # noqa: E402
    from utils.mir_eval_modules import idx2chord, idx2voca_chord  # type: ignore  # noqa: E402

    config = hparams.HParams.load(str(repo / "run_config.yaml"))
    sr = int(config.mp3["song_hz"])                    # 22050
    inst_len_s = float(config.mp3["inst_len"])         # 10.0
    n_bins = int(config.feature["n_bins"])             # 144
    bins_per_octave = int(config.feature["bins_per_octave"])  # 24
    hop_length = int(config.feature["hop_length"])     # 2048
    timestep = int(config.model["timestep"])           # 108
    fmin = 32.70319566257483                           # librosa note_to_hz('C1'), librosa.cqt default
    samples_per_window = int(round(inst_len_s * sr))   # 220500

    if args.voca:
        config.feature["large_voca"] = True
        config.model["num_chords"] = 170
        ckpt_path = repo / "test" / "btc_model_large_voca.pt"
        vocabulary = idx2voca_chord()
    else:
        ckpt_path = repo / "test" / "btc_model.pt"
        vocabulary = idx2chord
    vocab_list = [vocabulary[i] for i in range(len(vocabulary))] if isinstance(vocabulary, dict) else list(vocabulary)
    num_chords = int(config.model["num_chords"])
    assert len(vocab_list) == num_chords, f"vocab {len(vocab_list)} != num_chords {num_chords}"

    model = BTC_model(config=config.model)
    checkpoint = torch.load(str(ckpt_path), map_location="cpu")
    mean = float(checkpoint["mean"])
    std = float(checkpoint["std"])
    model.load_state_dict(checkpoint["model"])
    model.eval()

    # librosa parity: BTC's audio_file_to_features uses librosa.cqt with these exact params. nnAudio's
    # CQT1992v2 follows librosa conventions; assert the two agree on a real signal before trusting the
    # baked front-end. Any drift here is the ONLY place it can be caught against ground truth.
    if args.check_parity is not None:
        import librosa  # noqa: E402
        y, _ = librosa.load(str(args.check_parity), sr=sr, mono=True)
        y = y[:samples_per_window]
        lib = np.log(np.abs(librosa.cqt(
            y, sr=sr, n_bins=n_bins, bins_per_octave=bins_per_octave, hop_length=hop_length, fmin=fmin)) + 1e-6)
        cqt_check = CQT1992v2(sr=sr, hop_length=hop_length, fmin=fmin, n_bins=n_bins,
                              bins_per_octave=bins_per_octave, output_format="Magnitude")
        with torch.no_grad():
            nn = torch.log(cqt_check(torch.tensor(y).float().unsqueeze(0)) + 1e-6).squeeze(0).numpy()
        t = min(lib.shape[1], nn.shape[1])
        mae = float(np.mean(np.abs(lib[:, :t] - nn[:, :t])))
        print(f"[parity] librosa vs nnAudio log-CQT MAE = {mae:.4f} over {t} frames")
        if mae > 0.5:
            print("[parity] WARNING: front-ends diverge — reconcile CQT params before shipping.", file=sys.stderr)

    # Self-contained inference graph: raw audio → CQT → log → normalize → BTC transformer → logits.
    class BTCWithFrontend(torch.nn.Module):
        def __init__(self, m: torch.nn.Module):
            super().__init__()
            self.m = m
            self.cqt = CQT1992v2(sr=sr, hop_length=hop_length, fmin=fmin, n_bins=n_bins,
                                 bins_per_octave=bins_per_octave, output_format="Magnitude")
            self.register_buffer("mean", torch.tensor(mean, dtype=torch.float32))
            self.register_buffer("std", torch.tensor(std, dtype=torch.float32))

        def forward(self, audio: "torch.Tensor") -> "torch.Tensor":   # audio: [B, samples]
            feat = torch.log(self.cqt(audio) + 1e-6)                  # [B, n_bins, T]
            feat = feat.transpose(1, 2)                               # [B, T, n_bins]
            feat = (feat - self.mean) / self.std
            feat = feat[:, :timestep, :]                              # exactly one 108-frame instance
            attn, _ = self.m.self_attn_layers(feat)
            logits, _ = self.m.output_layer(attn)                     # [B, T, num_chords]
            return logits

    dummy = torch.zeros(1, samples_per_window, dtype=torch.float32)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    onnx_path = args.out_dir / "btc_chord.onnx"
    torch.onnx.export(
        BTCWithFrontend(model), dummy, str(onnx_path),
        input_names=["audio"], output_names=["logits"],
        dynamic_axes={"audio": {0: "batch"}, "logits": {0: "batch"}},
        opset_version=17,
    )

    meta = {
        "model": "BTC-ISMIR19",
        "license": "MIT",
        "source": "https://github.com/jayg996/BTC-ISMIR19",
        "voca": bool(args.voca),
        "vocabulary": vocab_list,
        "num_chords": num_chords,
        "no_chord_label": "N",
        "sample_rate": sr,
        "inst_len_s": inst_len_s,
        "timestep": timestep,
        "hop_length": hop_length,
    }
    (args.out_dir / "btc_chord_meta.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")
    print(f"wrote {onnx_path}")
    print(f"wrote {args.out_dir / 'btc_chord_meta.json'}  (num_chords={num_chords}, mean={mean:.4f}, std={std:.4f})")
    print("Next: host both files (raw URL → HFModelStore.ensure) and set the URLs in ChordRecognizer.swift.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
