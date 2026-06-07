# RX 6600 + llama.cpp Vulkan — Optimizing 35B MoE Models on RDNA2

[中文版](README.md)

> **TL;DR**: An 8GB RX 6600 (RDNA2) running `Qwen3.6-35B-A3B` via Vulkan backend achieves **18.6 t/s** with the right settings. Unlike Polaris (RX 580), RDNA2 does **NOT** need `GGML_VK_ALLOW_GRAPHICS_QUEUE=1` — setting it actually hurts performance by 20%.

---

## What This Guide Covers

This is a complete tuning guide for running `Qwen3.6-35B-A3B` (a 35B parameter MoE model, ~20GB quantized) on an RX 6600 8GB via the llama.cpp Vulkan backend.

This guide is for:
- Anyone wanting to run large models on AMD GPUs
- RX 6600 / 6600 XT / 6650 XT (RDNA2, 8GB) owners
- People tuning llama.cpp Vulkan parameters
- Those upgrading from RX 580 / RX 590 and wanting to know the real gains

---

## Performance Summary

### RX 6600 vs Other GPUs (Qwen3.6-35B-A3B Q4_K_M)

| GPU | Architecture | VRAM | Backend | decode t/s | Notes |
|:----|:-------------|:----:|:-------:|:----------:|:------|
| RX 580 2048SP | Polaris (GCN4) | 8 GB | Vulkan | 16.3 | Requires `GGML_VK_ALLOW_GRAPHICS_QUEUE=1` |
| **RX 6600** | **RDNA2** | **8 GB** | **Vulkan** | **18.6** | No special env vars needed |
| GTX 1070 | Pascal | 8 GB | CUDA | 22.3 | NVIDIA reference |

The RX 6600 is ~**14% faster** than the RX 580 with simpler setup.

---

## Test Environment

| Component | Spec |
|:----------|:-----|
| **CPU** | Intel Xeon E5-2666 v3 @ 2.90GHz (10C/20T) |
| **Motherboard** | Huananzhi X99 (DDR3 quad-channel) |
| **RAM** | 64 GB DDR3 1600 MHz (quad-channel) |
| **GPU** | AMD Radeon RX 6600 8 GB (MSI MECH 2X) |
| **GPU Driver** | AMD Adrenalin 32.0.21043.12001 |
| **Vulkan API** | fp16 + int dot product supported (RDNA2 advantage) |
| **OS** | Windows 10 |
| **llama.cpp** | b9547 (Vulkan build) |

### About the X99 + E5-2666 v3 Platform

This is a popular budget combo in China — server-grade CPUs paired with Huananzhi (華南金牌) X99 motherboards. Huananzhi is a well-known domestic brand for X99 boards, supporting DDR3 quad-channel with decent stability at low prices. Pros: many cores, large memory capacity, low price. Cons: DDR3 bandwidth (though quad-channel helps), lower single-thread performance.

For LLM inference:
- **DDR3 1600 quad-channel bandwidth is ~51.2 GB/s** — expert layers on CPU benefit from quad-channel
- **10 cores / 20 threads** is more than enough; llama.cpp optimal threads is typically 4–8
- **64 GB RAM** comfortably fits the 20GB model + KV cache without swapping

If you're running a Xeon E5-2666 v3 or similar E5 v3 series, the settings in this guide apply directly.

---

## The Key Difference: RDNA2 vs Polaris

### RX 580 (Polaris) Needs GGML_VK_ALLOW_GRAPHICS_QUEUE=1

The RX 580 has a Vulkan queue family bug: llama.cpp defaults to avoiding QF0 (which has GRAPHICS), selecting QF1 as the compute queue. But AMD's Polaris driver segfaults on QF1.

Fix: `GGML_VK_ALLOW_GRAPHICS_QUEUE=1` forces QF0 usage.

### RX 6600 (RDNA2) Does NOT Need It — It Hurts Performance

RDNA2's Vulkan queue families work correctly. The dedicated compute queue functions properly without any workaround.

Benchmark data:

| Setting | GGML_VK_ALLOW_GRAPHICS_QUEUE | decode t/s |
|:--------|:----------------------------:|:----------:|
| Not set | — | **17.24** |
| Set to 1 | 1 | **13.89** ← 20% slower |

**Conclusion: Polaris cards (RX 580/590) must set it. RDNA2+ cards (RX 6600/6700/6800/6900) should NOT set it.**

---

## Recommended Settings

```
llama-server.exe \
  -m Qwen3.6-35B-A3B-Q4_K_M.gguf \
  -ngl 99 \
  --device Vulkan0 \
  -t 8 \
  -c 32768 \
  -fa on \
  --cache-type-k q8_0 \
  --cache-type-v q8_0 \
  -fit off \
  --no-mmap \
  --n-cpu-moe 30 \
  --port 8080
```

### Parameter Breakdown

| Parameter | Value | Why |
|:----------|:------|:----|
| `-ngl 99` | All layers on GPU | Offload everything possible |
| `-t 8` | 8 CPU threads | Tested 4/6/8/10; **8 is optimal** (18.6 t/s) |
| `-c 32768` | 32K context | Stable with q8_0 KV cache |
| `-fa on` | Flash Attention | **Must enable** — otherwise KV cache grows linearly |
| `--cache-type-k q8_0` | KV cache quantization | Half the VRAM vs f16 |
| `--cache-type-v q8_0` | Same | Same |
| `--n-cpu-moe 30` | 226 experts on GPU | Sweet spot for 8GB VRAM |
| `--no-mmap` | No mmap | Avoids overhead |
| `-fit off` | No auto-adjust | Keeps things stable |

### About `--n-cpu-moe`

This parameter controls how many MoE experts are placed on CPU:
- `--n-cpu-moe 30` = 30 experts on CPU, 226 on GPU
- Fewer experts on GPU → faster decode, but tighter VRAM
- With 8GB VRAM, 30 is the sweet spot (~6.7 GB VRAM used)

---

## `-t` (Threads) Tuning Results

This is one of the most impactful parameters.

| -t | decode t/s | vs Best |
|:--:|:----------:|:-------:|
| 4 | 17.39 | -7% |
| 6 | 18.55 | -0.4% |
| **8** | **18.63** | **Best** |
| 10 | 17.00 | -9% |

**Conclusion: -t 8 is optimal for the Xeon E5-2666 v3.** Going above 8 causes CPU contention and slows things down.

> Note: The optimal `-t` varies by CPU. If you have a different processor, test 4/6/8/10 yourself.

---

## The tg256 Performance Anomaly

A quirk was discovered in llama.cpp's Vulkan backend:

| Generation Length | decode t/s |
|:-----------------:|:----------:|
| tg64 | 17.21 |
| tg96 | 17.17 |
| tg128 | 17.29 |
| tg160 | 17.18 |
| tg192 | 17.18 |
| tg224 | 17.09 |
| **tg256** | **10.04** ← sudden drop |
| tg288 | 17.30 ← back to normal |
| tg320 | 17.19 |

**Only tg256 drops in speed.** This is a boundary effect in the llama.cpp Vulkan backend on RDNA2 — not a settings issue.

Minimal impact for daily use (chat replies rarely hit exactly 256 tokens), but if you notice a particularly slow response, this bug may be the cause.

---

## GPU Comparison: RDNA2 vs Polaris

| Feature | RX 580 (Polaris) | RX 6600 (RDNA2) |
|:--------|:-----------------|:----------------|
| VRAM | 8 GB GDDR5 | 8 GB GDDR6 |
| Memory Bandwidth | ~224 GB/s | 224 GB/s |
| fp16 Support | ❌ No hardware support | ✅ Hardware accelerated |
| Int Dot Product | ❌ | ✅ |
| Matrix Cores | ❌ | ❌ |
| Vulkan Compute Queue | Buggy (needs workaround) | Works correctly |
| Optimal `-t` | 4 | 8 |
| Needs GGML_VK_ALLOW_GRAPHICS_QUEUE | ✅ Required | ❌ Don't set |
| Qwen3.6-35B decode | 16.3 t/s | 18.6 t/s |

RDNA2's fp16 and int dot product hardware support are the main advantages, improving quantized model efficiency.

---

## Quick Start

### 1. Download llama.cpp Vulkan Build

```bash
# Download from GitHub releases
# https://github.com/ggml-org/llama.cpp/releases
# Select llama-bXXXX-bin-win-vulkan-x64.zip
```

### 2. Verify GPU Detection

```bash
llama-server.exe --list-devices
# Should show: Vulkan0: AMD Radeon RX 6600 (8176 MiB)
```

### 3. Download Model

```bash
# Qwen3.6-35B-A3B Q4_K_M (~20GB)
# Download GGUF format from HuggingFace
```

### 4. Start Server

```bash
llama-server.exe ^
  -m Qwen3.6-35B-A3B-Q4_K_M.gguf ^
  -ngl 99 --device Vulkan0 -t 8 ^
  -c 32768 -fa on ^
  --cache-type-k q8_0 --cache-type-v q8_0 ^
  -fit off --no-mmap ^
  --n-cpu-moe 30 --port 8080
```

### 5. Open Browser

```
http://localhost:8080
```

---

## Known Limitations

1. 8GB VRAM limit: Cannot fit all 256 experts on GPU; requires `--n-cpu-moe` to split
2. tg256 performance anomaly: Known quirk in llama.cpp Vulkan backend
3. DDR3 bandwidth bottleneck: Huananzhi X99 DDR3 quad-channel bandwidth is ~51.2 GB/s, better than dual-channel but still below DDR4
4. No matrix cores on RDNA2: Unlike RDNA3 / CDNA, no dedicated matrix compute units

---

## Related Projects

- [castlen3/rx580-llamacpp-vulkan-guide](https://github.com/castlen3/rx580-llamacpp-vulkan-guide) — RX 580 2048SP optimization guide for the same model
- [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) — llama.cpp itself

---

## Test Date

2026-06-07

---

*If this guide helped you, please star ⭐ so more people can find it!*
