# Local models

Notes from October 2026. Model rankings change quickly and most of the guides are SEO-driven and contradict each
other, so treat the model names as starting points and test on the actual hardware.

## What fits now: 8 GB VRAM (RTX 3060 Ti)

Rule of thumb: VRAM needed is roughly the Q4_K_M file size plus 1 to 1.5 GB for context. About 0.55 GB per billion
parameters at 4-bit. The KV cache, not the weights, is usually what causes out-of-memory errors.

| Model | Good for | Notes |
|---|---|---|
| Qwen3.5 9B (Q4_K_M) | General: coding, reasoning, multilingual, images | Most-recommended recent pick; one benchmark on an 8 GB card reported about 55 tok/s with 32K context in about 7 GB |
| Qwen2.5 Coder 7B | Pure coding, autocomplete | About 5 GB, about 50 tok/s; older but purpose-built |
| DeepSeek-Coder 6.7B | Fill-in-the-middle autocomplete | |
| Gemma 4 E4B, Qwen3 8B, Llama 3.1 8B | Lightweight general tasks | |

Skip 14B models on 8 GB; there's no room left for context.

Settings: Q4_K_M (avoid Q3 for code), offload all layers to the GPU (`--n-gpu-layers 99`; Ollama does it automatically),
start at 8K context and raise it while watching `nvidia-smi`, check placement with `ollama ps`.

Running the server headless frees about 0.5 GB of VRAM compared with a desktop session.

## What these models are for

Short utility functions, boilerplate, explanations, triage, log summaries, embeddings. They are **sidecars**, not
the main agent: large multi-file agentic coding still needs a frontier API model.

## If we wanted to host bigger models

VRAM is the constraint, then memory bandwidth. CPU, NVMe and the board are fine.

| VRAM | What fits (4-bit) | How |
|---|---|---|
| 8 GB (now) | about 7 to 8B | current card |
| 16 GB | about 14B | RTX 5080-class |
| 24 GB | about 30 to 32B coding models | used RTX 3090, or 4090 |
| 32 GB | about 32B with long context | RTX 5090 |
| 48 GB | about 70B | two 24 GB cards |

1. **Used RTX 3090 (24 GB)**: best value per GB. llama.cpp can split across mismatched GPUs, so it can sit alongside the 3060 Ti (32 GB total). Check PSU wattage (about 350 W for the card) and case clearance first.
2. **More system RAM (64 to 128 GB)**: cheap on DDR4. Helps mixture-of-experts models (large total size, few active parameters) by keeping the busy parts on the GPU and the rest in RAM. Doesn't help dense models much (DDR4 is about 50 GB/s).
3. **Two 3090s (48 GB)**: runs 70B. Needs about a 1000 W PSU, space and cooling; the second slot running at x4 is fine for inference.
4. **RTX 5090 (32 GB)**: fastest single consumer card, expensive and about 575 W.

Different approach, not an upgrade: Apple Silicon or AMD Strix Halo machines with 96 to 512 GB of unified memory run huge models, but slowly.

Suggested path: try a small model on the current card first and see whether sidecar work is useful before buying anything.
