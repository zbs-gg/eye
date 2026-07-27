# Third-party notices

ZBS Eye uses open-source software and optional model assets. This file records the attribution required
for the call-speaker feature; dependency source distributions retain their own license files.

## transcribe.cpp

- Project: [handy-computer/transcribe.cpp](https://github.com/handy-computer/transcribe.cpp)
- Version: `0.1.3`
- Copyright: 2026 The transcribe.cpp authors
- License: MIT
- Changes in ZBS Eye: no vendored source modification. ZBS Eye links the checksum-pinned universal
  framework and uses it only in a short-lived local helper to read a compatible model already present
  in Handy's Hugging Face cache. Handy.app is never launched and model weights are not copied.
- Full transcribe.cpp, ggml, and miniz license texts are bundled in
  `ZBSEyeApp/Resources/LOCAL_AI_NOTICES.txt`.

## FluidAudio

- Project: [FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)
- Version: `0.15.5` (`19600a485baa4998812e4654b70d2bab8f2c9949`)
- Copyright: FluidInference contributors
- License: Apache License 2.0
- Changes in ZBS Eye: no vendored source modification; ZBS Eye links the pinned Swift package and isolates
  its offline diarization API behind a local helper boundary.

## FluidInference speaker diarization Core ML models

- Work: [FluidInference/speaker-diarization-coreml](https://huggingface.co/FluidInference/speaker-diarization-coreml)
- Revision: `1ed7a662fdc7109e36d822db793ee6eebdaf8594`
- Creator/adapter: Fluid Inference
- License: Creative Commons Attribution 4.0 International (CC BY 4.0)
- License text: [creativecommons.org/licenses/by/4.0](https://creativecommons.org/licenses/by/4.0/)
- Changes in ZBS Eye: no model-weight modification. ZBS Eye downloads only the checksum-pinned compiled
  Core ML files and uses them locally for anonymous, per-call speaker clustering.

The model card also credits the upstream research and model authors whose work underlies segmentation,
speaker embeddings, and VBx clustering. See the linked model card for the complete citation list.
