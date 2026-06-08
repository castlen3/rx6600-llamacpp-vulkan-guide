# Gemma 4 12B 64K Tuning Log (RX 6600 / Vulkan)

This log preserves the reasoning behind the final daily-driver settings for running `gemma-4-12b-it-UD-Q4_K_XL.gguf` at 64K context on an 8GB RX 6600. The key is not just whether 64K can start, but whether long-prefill remains stable without swap-like behavior and catastrophic slowdown.

## Test target

- GPU: AMD Radeon RX 6600 8GB
- backend: llama.cpp Vulkan
- model: `gemma-4-12b-it-UD-Q4_K_XL.gguf`
- target: keep `-c 65536` usable with as little slowdown as possible and avoid swap / late-prefill collapse

## Observed failure pattern

With settings that are too aggressive, 64K may still start successfully, but once a long prompt is fed in, the real failure mode appears:

- prefill starts fine, then collapses in the middle or late phase
- GPU usage becomes sawtoothed (high load alternating with near-idle)
- Windows becomes sluggish
- pagefile / swap pressure rises

This means the real bottleneck is not startup, but the host-memory / staging / VRAM margin being exhausted during late prefill.

## What was tested and what mattered

### 1. Lowering batch alone: helps, but not enough

- Lower `-b` / `-ub` does reduce prefill spikes
- But if `-ngl` is still too high, late-prefill can still collapse
- Conclusion: batch is only a supporting knob, not the main knob

### 2. `--mmap`: necessary

- In this case, `--mmap` is more stable than `--no-mmap`
- It keeps host-side memory pressure more manageable

### 3. Conservative KV cache: necessary

- Final choice: `--cache-type-k q4_0 --cache-type-v q4_0`
- The goal here is stability at 64K first, not theoretical quality maximization

### 4. The real master knob is `-ngl`

High-level summary:

- `-ngl 40`: stable
- `-ngl 44`: stable
- `-ngl 45`: stable, and the best final compromise
- `-ngl 46`: collapses

Conclusion: the 64K sweet spot is `-ngl 44–45`, with `-ngl 45` chosen as the final setting.

## Final daily-driver settings

```bat
llama-server.exe -m gemma-4-12b-it-UD-Q4_K_XL.gguf -ngl 45 --device Vulkan0 -t 8 -tb 6 -c 65536 -b 512 -ub 256 -fa on --cache-type-k q4_0 --cache-type-v q4_0 -fit off --mmap -np 1 --host 0.0.0.0 --port 8080
```

Matching downloadable batch file:
- [start_gemma4_12b_vulkan_rx6600_64k_FINAL.bat](start_gemma4_12b_vulkan_rx6600_64k_FINAL.bat)

## Why this set is the best compromise

- `-ngl 45`: slightly more GPU offload than 44 while still staying stable
- `-b 512 / -ub 256`: reduces prefill spikes
- `q4_0 / q4_0 KV`: one of the keys to making 64K stable
- `--mmap`: keeps host-side pressure more controlled than `--no-mmap`
- `-fa on`: mandatory for long context

## One-line takeaway

> For Gemma 4 12B UD Q4_K_XL at 64K context on an 8GB RX 6600, the best low-slowdown stable compromise is not just shrinking batch, but `-ngl 45 + q4_0/q4_0 KV + b512/ub256 + mmap + flash-attn on`.
