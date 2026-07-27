# On-device model integrity

NexGenVideo treats downloaded ONNX and GGML files as executable dependencies. Every production
download uses an immutable upstream revision and a host-pinned SHA-256. Cached files and new
downloads are verified before an inference runtime can open them.

| Consumer | Source and immutable revision | File | Bytes | SHA-256 | License |
|---|---|---|---:|---|---|
| BeatThis | [`mosynthkey/beat_this_cpp@07ab790`](https://github.com/mosynthkey/beat_this_cpp/tree/07ab790a9ec2eda8093d52d249e3ec4f0510ee72) | `onnx/beat_this.onnx` | 83,077,778 | `c5c1466e08abdb03fdeb50668a06f244b787d564c212490482231a9cfbe9ccbd` | MIT |
| Demucs vocals | [`StemSplitio/htdemucs-ft-vocals-onnx@2ef0d75`](https://huggingface.co/StemSplitio/htdemucs-ft-vocals-onnx/tree/2ef0d757d3e226d0da85fb8c71514f464fcabdd0) | `htdemucs_ft_vocals.onnx` | 316,446,953 | `8c5d5e2da1f27050240bb80236673307ee3b40d4b064066d9350f4d64bfd544d` | MIT |
| Whisper | [`ggerganov/whisper.cpp@5359861`](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1) | `ggml-large-v3-turbo.bin` | 1,624,555,275 | `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` | MIT |
| Whisper | same revision | `ggml-medium.bin` | 1,533,763,059 | `6c14d5adee5f86394037b4e4e8b59f1673b6cee10e3cf0b11bbdbee79c156208` | MIT |
| Whisper | same revision | `ggml-small.bin` | 487,601,967 | `1be3a9b2063867b937e64e2ec7483364a79917e157fa98c5d94b5c1fffea987b` | MIT |

`NGV_WHISPER_MODEL` accepts only `large-v3-turbo`, `medium`, or `small`. An unknown value fails
before download; it cannot construct an unverified upstream URL.

`HFModelStore` removes an invalid cached file, downloads to a temporary sibling, verifies minimum
size and SHA-256, and only then installs the file atomically into the model cache. A wrong download
is removed and returned as an error.

The BTC chord model is NexGenVideo-controlled and documented separately in
[`CHORD_MODEL.md`](CHORD_MODEL.md); its release URLs and both checksums are pinned in
`ChordRecognizer`.
