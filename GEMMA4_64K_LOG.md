# Gemma 4 12B 64K 調校紀錄（RX 6600 / Vulkan）

這份 log 保留這次把 `gemma-4-12b-it-UD-Q4_K_XL.gguf` 壓到 RX 6600 8GB 可日用 64K context 的決策脈絡，重點不是只看能不能啟動，而是 long-prefill 後段能不能避免 swap 與崩速。

## 測試目標

- GPU：AMD Radeon RX 6600 8GB
- backend：llama.cpp Vulkan
- model：`gemma-4-12b-it-UD-Q4_K_XL.gguf`
- target：`-c 65536` 下盡量不 swap、速度掉最少、避免 prefill 後段 collapse

## 觀察到的症狀

當設定太激進時，64K 雖然可能成功啟動，但長 prompt 灌入之後會出現：

- prefill 前段正常，中後段明顯崩速
- GPU usage 出現鋸齒波（高負載 / 掉到接近 0 反覆循環）
- Windows 整體反應變鈍
- pagefile / swap 壓力上升

這代表真正的瓶頸不是「能不能開」，而是 host memory / staging / VRAM 餘裕在 late-prefill 被吃光。

## 實測方向與結論

### 1. 單降 batch：有幫助，但不足

- 降 `-b` / `-ub` 可以稍微舒緩 prefill 尖峰
- 但如果 `-ngl` 太高，後段還是可能 collapse
- 結論：batch 不是主旋鈕，只能當輔助旋鈕

### 2. `--mmap`：必要

- 這個 case 用 `--mmap` 比 `--no-mmap` 更穩
- 可減少 host memory 壓力過早放大

### 3. KV cache 要保守

- 最後定稿採用：`--cache-type-k q4_0 --cache-type-v q4_0`
- 目的不是追求理論最佳品質，而是先把 64K 壓穩

### 4. 真正關鍵是 `-ngl`

大方向可整理成：

- `-ngl 40`：穩
- `-ngl 44`：穩
- `-ngl 45`：穩，且是較好的最終折衷
- `-ngl 46`：崩

結論：64K 甜蜜點落在 `-ngl 44–45`，最終定稿 `-ngl 45`。

## 最終日用設定

```bat
llama-server.exe -m gemma-4-12b-it-UD-Q4_K_XL.gguf -ngl 45 --device Vulkan0 -t 8 -tb 6 -c 65536 -b 512 -ub 256 -fa on --cache-type-k q4_0 --cache-type-v q4_0 -fit off --mmap -np 1 --host 0.0.0.0 --port 8080
```

對應可直接下載的批次檔：
- [start_gemma4_12b_vulkan_rx6600_64k_FINAL.bat](start_gemma4_12b_vulkan_rx6600_64k_FINAL.bat)

## 為什麼這組最合理

- `-ngl 45`：比 44 多拿一點 GPU offload，但仍維持穩定
- `-b 512 / -ub 256`：把 prefill 尖峰壓下來
- `q4_0 / q4_0 KV`：是 64K 能壓穩的重要條件之一
- `--mmap`：讓 host side 壓力比 `--no-mmap` 更可控
- `-fa on`：長 context 必開

## 一句話版結論

> RX 6600 8GB 跑 Gemma 4 12B UD Q4_K_XL 的 64K context，最穩且掉速最少的折衷，不是單純縮 batch，而是 `-ngl 45 + q4_0/q4_0 KV + b512/ub256 + mmap + flash-attn on`。
