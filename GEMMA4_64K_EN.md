# RX 6600 + Gemma 4 12B UD Q4_K_XL — 64K Context Long-Prefill Tuning Notes

This note covers a different workload than the main README:

- GPU: AMD Radeon RX 6600 8GB (RDNA2)
- backend: llama.cpp Vulkan
- model: `gemma-4-12b-it-UD-Q4_K_XL.gguf`
- goal: make 64K context usable without long-prefill collapse, swap storms, or sawtooth GPU usage

Short version:

> `-ngl 45` turned out to be the final stable sweet spot for Gemma 4 12B at 64K on this RX 6600. `-ngl 46` collapsed. Reducing batch alone helped a little, but did not solve late-prefill instability.

---

## What the failure looked like

At first glance, 64K seemed fine because:
- the server started
- `/health` returned OK
- short completions worked

But once a truly long prompt was fed in, the real bottleneck showed up:

- prefill started okay, then collapsed later in the prompt
- GPU usage became sawtooth-shaped: burst high, then drop to zero
- Windows became sluggish
- pagefile activity increased, strongly suggesting swap / paging pressure

This means the issue was not "can it start?" but rather:

- VRAM / host staging / RAM pressure accumulating during long prefill
- the GPU no longer receiving a steady stream of work because CPU / RAM / page faults were stalling the pipeline

---

## What was tested

### 1) Reducing batch only: some improvement, not enough

Lowering batch / ubatch made early prefill a bit smoother, but late-prefill collapse could still happen.

Conclusion:
- oversized batch does make prefill pressure worse
- but it is not the main lever here
- batch-only tuning was insufficient for stable 64K long-prefill

### 2) Switching to mmap: necessary

`--no-mmap` made host-side memory pressure tighter in this workload.

The practical choice here was:
- `--mmap`

### 3) Conservative KV cache: necessary

To stabilize 64K, the final setup used:
- `--cache-type-k q4_0`
- `--cache-type-v q4_0`

### 4) The real control knob: lowering `-ngl`

The initial intuition was to reduce batch first, but the actual results showed:

- `-ngl 40`: very stable
- `-ngl 44`: stable
- `-ngl 45`: stable, with slightly more GPU offload than 44
- `-ngl 46`: collapsed

So the real sweet spot was not 48 and not "batch tuning only", but:

> `-ngl 44–45`

The final choice was `-ngl 45`.

---

## Final stable settings

```bat
llama-server.exe ^
  -m gemma-4-12b-it-UD-Q4_K_XL.gguf ^
  -ngl 45 ^
  --device Vulkan0 ^
  -t 8 ^
  -tb 6 ^
  -c 65536 ^
  -b 512 ^
  -ub 256 ^
  -fa on ^
  --cache-type-k q4_0 ^
  --cache-type-v q4_0 ^
  -fit off ^
  --mmap ^
  -np 1 ^
  --host 0.0.0.0 --port 8080
```

---

## Parameter breakdown

| Parameter | Value | Why it mattered |
|:----------|:------|:----------------|
| `-ngl` | `45` | final stable sweet spot; 46 collapsed |
| `-t` | `8` | generation threads |
| `-tb` | `6` | batch / prompt-processing threads |
| `-c` | `65536` | 64K context |
| `-b` | `512` | keeps prefill scratch pressure under control |
| `-ub` | `256` | lowers peak staging pressure |
| `-fa on` | on | necessary for long context |
| `cache k/v` | `q4_0 / q4_0` | one of the key stabilizers for 64K |
| `--mmap` | on | avoids the extra host-memory pressure seen with `--no-mmap` |
| `-fit off` | on | keeps the configuration fixed and comparable |

---

## Practical conclusions

The most valuable lessons from this test:

1. 64K "starts successfully" does not mean 64K long-prefill is truly usable.
2. Sawtooth GPU usage + collapsing late-prefill usually means the host-memory / staging pipeline is failing, not simply that the GPU is weak.
3. On an RX 6600 8GB, the true Gemma 4 12B 64K sweet spot was `-ngl 44–45`.
4. If you reduce only batch but keep ngl too high, early prefill may look fine while late-prefill still collapses.
5. For daily use, `-ngl 45` is the finalized choice.

---

## Suggested re-test order

Keep these fixed:
- `-t 8`
- `-tb 6`
- `-c 65536`
- `-b 512`
- `-ub 256`
- `-fa on`
- `q4_0 / q4_0`
- `--mmap`

Then sweep only:
- `-ngl 40`
- `-ngl 42`
- `-ngl 44`
- `-ngl 45`
- `-ngl 46`

Do not judge by startup speed alone. Watch instead:
- whether early prefill is fast
- whether mid/late prefill remains stable
- whether GPU usage returns to a 100% / 0% sawtooth pattern
- whether pagefile usage starts growing abnormally

If `-ngl 46` collapses and `-ngl 45` stays stable, just lock in 45.

---

## One-line summary

> For Gemma 4 12B UD Q4_K_XL at 64K on an RX 6600 8GB, the real stable long-prefill solution was `-ngl 45 + q4/q4 KV + b512/ub256 + mmap + flash-attn on` — not merely "64K starts".
