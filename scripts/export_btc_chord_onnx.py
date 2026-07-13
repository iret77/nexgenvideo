#!/usr/bin/env python3
"""Export the BTC (Bi-directional Transformer for Chord recognition) inference path to ONNX.

Step 0 artifact for issue #192 (see docs/CHORD_MODEL.md). BTC (jayg996/BTC-ISMIR19) is MIT-licensed
and ships its pretrained checkpoints under the same license, so the model and its weights may be
bundled / runtime-downloaded in the commercial Developer-ID app. This script turns the MIT PyTorch
checkpoint into the two artifacts the NexGenVideo `ChordRecognizer` provider consumes:

  * btc_chord.onnx        — the transformer inference path (self_attn_layers → output_layer)
  * btc_chord_meta.json   — { mean, std, vocabulary, timestep, feature_size, num_chords, cqt{...} }

It is NOT run in CI (needs torch + the BTC repo). Run it once, on a machine with the deps, then host
the outputs the way beat_this.onnx / htdemucs are hosted (raw URL → HFModelStore.ensure).

Usage:
    git clone https://github.com/jayg996/BTC-ISMIR19
    pip install torch numpy pyyaml   # torch only needed for this export step
    python scripts/export_btc_chord_onnx.py \
        --btc-repo ./BTC-ISMIR19 \
        --voca false \
        --out-dir ./chord-model

The exported ONNX takes a float32 tensor [batch, timestep(=108), feature_size(=144)] already
normalized as (log(|CQT|+1e-6).T - mean) / std, and returns per-frame class logits
[batch, timestep, num_chords]. Arg-max + ChordDecode.segments(hopSeconds=inst_len/timestep) on the
Swift side reproduces BTC's exact decode. Reconcile the Swift CQT frontend against a librosa golden
generated from this same repo before enabling the provider — match the preprocessing code, not docs.
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
    args = ap.parse_args()

    repo = args.btc_repo.resolve()
    if not (repo / "btc_model.py").exists():
        print(f"error: {repo} is not a BTC-ISMIR19 checkout (no btc_model.py).", file=sys.stderr)
        return 2
    sys.path.insert(0, str(repo))

    import torch  # noqa: E402  (deferred; only this export step needs torch)
    from btc_model import BTC_model  # type: ignore  # noqa: E402
    from utils import hparams  # type: ignore  # noqa: E402
    from utils.mir_eval_modules import idx2chord, idx2voca_chord  # type: ignore  # noqa: E402

    config = hparams.HParams.load(str(repo / "run_config.yaml"))
    if args.voca:
        config.feature["large_voca"] = True
        config.model["num_chords"] = 170
        ckpt_path = repo / "test" / "btc_model_large_voca.pt"
        vocabulary = idx2voca_chord()
    else:
        ckpt_path = repo / "test" / "btc_model.pt"
        vocabulary = idx2chord

    # vocabulary may be a dict {idx: label} or a list — normalize to an index-ordered list.
    if isinstance(vocabulary, dict):
        vocab_list = [vocabulary[i] for i in range(len(vocabulary))]
    else:
        vocab_list = list(vocabulary)
    num_chords = config.model["num_chords"]
    assert len(vocab_list) == num_chords, f"vocab {len(vocab_list)} != num_chords {num_chords}"

    model = BTC_model(config=config.model)
    checkpoint = torch.load(str(ckpt_path), map_location="cpu")
    mean = float(checkpoint["mean"])
    std = float(checkpoint["std"])
    model.load_state_dict(checkpoint["model"])
    model.eval()

    # Wrap the inference path test.py runs: self_attn_layers → output_layer, returning per-frame logits.
    class BTCInference(torch.nn.Module):
        def __init__(self, m: torch.nn.Module):
            super().__init__()
            self.m = m

        def forward(self, x: "torch.Tensor") -> "torch.Tensor":  # x: [B, T, feature_size]
            attn, _ = self.m.self_attn_layers(x)
            logits, _ = self.m.output_layer(attn)  # [B, T, num_chords]
            return logits

    timestep = config.model["timestep"]
    feature_size = config.model["feature_size"]
    dummy = torch.zeros(1, timestep, feature_size, dtype=torch.float32)

    args.out_dir.mkdir(parents=True, exist_ok=True)
    onnx_path = args.out_dir / "btc_chord.onnx"
    torch.onnx.export(
        BTCInference(model), dummy, str(onnx_path),
        input_names=["features"], output_names=["logits"],
        dynamic_axes={"features": {0: "batch"}, "logits": {0: "batch"}},
        opset_version=17,
    )

    meta = {
        "model": "BTC-ISMIR19",
        "license": "MIT",
        "source": "https://github.com/jayg996/BTC-ISMIR19",
        "voca": bool(args.voca),
        "mean": mean,
        "std": std,
        "timestep": timestep,
        "feature_size": feature_size,
        "num_chords": num_chords,
        "vocabulary": vocab_list,
        "no_chord_label": "N",
        # Frontend contract — the Swift CQT must reproduce this exactly (see docs/CHORD_MODEL.md).
        "cqt": {
            "sample_rate": config.mp3["song_hz"],
            "inst_len_s": config.mp3["inst_len"],
            "n_bins": config.feature["n_bins"],
            "bins_per_octave": config.feature["bins_per_octave"],
            "hop_length": config.feature["hop_length"],
            "fmin_hz": 32.70319566257483,   # librosa note_to_hz('C1') — librosa.cqt default
            "magnitude": "log(abs(cqt) + 1e-6)",
            "normalize": "(feature.T - mean) / std",
            "time_unit_s": config.mp3["inst_len"] / timestep,
        },
    }
    meta_path = args.out_dir / "btc_chord_meta.json"
    meta_path.write_text(json.dumps(meta, indent=2), encoding="utf-8")

    print(f"wrote {onnx_path}")
    print(f"wrote {meta_path}  (mean={mean:.6f} std={std:.6f} num_chords={num_chords})")
    print("Next: host both files (raw URL → HFModelStore.ensure) and validate the Swift CQT frontend "
          "against a librosa golden before enabling the provider.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
