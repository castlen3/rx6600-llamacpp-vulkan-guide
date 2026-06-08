# RX 6600 + Gemma 4 12B UD Q4_K_XL — 64K Context Long-Prefill Tuning Notes

這份筆記記錄另一個和 README 主文不同的場景：

- GPU：AMD Radeon RX 6600 8GB (RDNA2)
- backend：llama.cpp Vulkan
- model：`gemma-4-12b-it-UD-Q4_K_XL.gguf`
- 目標：在 64K context 下避免 long-prefill 後段崩速 / swap / GPU usage 鋸齒化

結論先講：

> `-ngl 45` 是這張 RX 6600 跑 Gemma 4 12B 64K long-context 的最終穩定甜蜜點。`-ngl 46` 會崩，單純只降 batch 雖然有幫助，但不足以解決 late-prefill collapse。

---

## 問題現象

一開始直覺會以為：
- 64K 能成功啟動
- `/health` 正常
- 短 completion 也能回

那就代表 64K 可用。

但實際長 prompt 灌進去之後，真正的瓶頸才出現：

- prefill 速度前段還行，後段一路掉速
- GPU usage 呈現鋸齒狀：一下衝高、一下掉到 0
- Windows 反應變鈍
- pagefile 開始吃，像在瘋狂 swap

這表示問題不是「能不能啟動」，而是：

- VRAM / host staging / RAM 壓力在長 prefill 累積後失控
- GPU 吃不到穩定資料流，開始等 CPU / RAM / page fault

---

## 測過哪些方向

### 1) 只降 batch：有改善，但不夠

嘗試把 batch / ubatch 降低後，前段 prefill 會比較穩一點，但後段仍然可能掉進悲劇。

結論：
- batch 太大確實會加重 prefill 壓力
- 但這不是主因
- 只動 batch 無法真正救回 64K long-prefill 穩定性

### 2) 改用 mmap：必要

`--no-mmap` 在這個場景下會把 host 記憶體壓力推得更緊。

實戰上應改成：
- `--mmap`

### 3) KV cache 改保守：必要

為了把 64K 壓穩，最終使用：
- `--cache-type-k q4_0`
- `--cache-type-v q4_0`

### 4) 真正有效的主旋鈕：降低 `-ngl`

一開始以為先砍 batch 就夠，但後來實測證明：

- `-ngl 40`：非常穩
- `-ngl 44`：穩
- `-ngl 45`：穩，且比 44 多一點 GPU offload
- `-ngl 46`：崩

所以甜蜜點不是 48，也不是單靠 batch 微調，而是：

> `-ngl 44–45`

最後定稿選 `-ngl 45`。

---

## 最終穩定參數

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

## 參數解讀

| 參數 | 值 | 作用 |
|:-----|:---|:-----|
| `-ngl` | `45` | 最終穩定甜蜜點；46 會崩 |
| `-t` | `8` | generation threads |
| `-tb` | `6` | batch / prompt processing threads |
| `-c` | `65536` | 64K context |
| `-b` | `512` | logical batch size，避免 prefill 暫存壓力太高 |
| `-ub` | `256` | physical batch size，降低尖峰壓力 |
| `-fa on` | 開 | 長 context 必開 |
| `cache k/v` | `q4_0 / q4_0` | 把 64K 壓穩的關鍵之一 |
| `--mmap` | 開 | 避免 `--no-mmap` 帶來更高 host memory 壓力 |
| `-fit off` | 開 | 固定參數，不讓自動調整混入結果 |

---

## 實戰結論

這次測試最有價值的地方是：

1. 64K「能啟動」不代表「能穩定 long-prefill」
2. GPU 鋸齒波 + 後段 prefill 暴跌，通常不是單純 GPU 弱，而是整個 host-memory / staging pipeline 在抖
3. 在 RX 6600 8GB 上，Gemma 4 12B 64K 真正的甜蜜點是 `-ngl 44–45`
4. 如果只降 batch，不降 ngl，常常前段好看、後段還是崩
5. 日用最終版可以直接選 `-ngl 45`

---

## 建議測試順序（給想自己重跑的人）

固定這些：
- `-t 8`
- `-tb 6`
- `-c 65536`
- `-b 512`
- `-ub 256`
- `-fa on`
- `q4_0 / q4_0`
- `--mmap`

然後只 sweep：
- `-ngl 40`
- `-ngl 42`
- `-ngl 44`
- `-ngl 45`
- `-ngl 46`

判斷標準不要看啟動速度，而要看：
- prefill 前段是否快
- prefill 中後段是否還能維持
- GPU usage 是否重新出現 100% / 0% 鋸齒
- pagefile 是否開始異常增長

如果 `-ngl 46` 崩、`-ngl 45` 穩，那就直接定稿 45。

---

## 一句話總結

> RX 6600 8GB 跑 Gemma 4 12B UD Q4_K_XL 的 64K context，不要只看能不能開；真正穩定 long-prefill 的最終解，是 `-ngl 45 + q4/q4 KV + b512/ub256 + mmap + flash-attn on`。
