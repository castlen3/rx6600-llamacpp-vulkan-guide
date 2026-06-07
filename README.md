# RX 6600 + llama.cpp Vulkan — RDNA2 跑 35B MoE 大模型優化指南

[English Version](README_EN.md)

> **TL;DR**: 8GB VRAM 的 RX 6600（RDNA2）透過 Vulkan 後端跑 `Qwen3.6-35B-A3B`，最佳設定可達 **18.6 t/s**。跟 Polaris 架構的 RX 580 不同，RDNA2 **不需要** `GGML_VK_ALLOW_GRAPHICS_QUEUE=1`，設了反而慢 20%。

---

## 這份指南在記錄什麼

我在一張 RX 6600 8GB 上測試 `Qwen3.6-35B-A3B`（35B 參數的 MoE 模型，量化後 ~20GB），記錄完整的參數調校過程、踩坑經驗、以及最終推薦設定。

這份指南適合：
- 想用 AMD 顯卡跑大模型的人
- 手上有 RX 6600 / 6600 XT / 6650 XT 等 RDNA2 8GB 卡的人
- 想知道 Vulkan 後端怎麼調參數的人
- 從 RX 580 / RX 590 升級上來，想確認新卡能快多少的人

---

## 效能總覽

### RX 6600 vs 其他卡（Qwen3.6-35B-A3B Q4_K_M）

| 顯卡 | 架構 | VRAM | 後端 | decode t/s | 備註 |
|:-----|:-----|:----:|:----:|:----------:|:-----|
| RX 580 2048SP | Polaris (GCN4) | 8 GB | Vulkan | 16.3 | 需要 `GGML_VK_ALLOW_GRAPHICS_QUEUE=1` |
| **RX 6600** | **RDNA2** | **8 GB** | **Vulkan** | **18.6** | 不需要特殊環境變數 |
| GTX 1070 | Pascal | 8 GB | CUDA | 22.3 | NVIDIA 對照組 |

RX 6600 比 RX 580 快約 **14%**，而且設定更簡單。

---

## 測試環境

| 項目 | 規格 |
|:-----|:-----|
| **CPU** | Intel Xeon E5-2666 v3 @ 2.90GHz（10C/20T） |
| **主機板** | X99 平台（DDR3） |
| **RAM** | 64 GB DDR3 1600 MHz |
| **GPU** | AMD Radeon RX 6600 8 GB（MSI MECH 2X） |
| **GPU 驅動** | AMD Adrenalin 32.0.21043.12001 |
| **Vulkan API** | 支援 fp16、int dot product（RDNA2 優勢） |
| **OS** | Windows 10 |
| **llama.cpp** | b9547（Vulkan build） |

### 關於 X99 + E5-2666 v3

這是淘寶上很常見的「洋垃圾」組合——伺服器級 CPU + 便宜的 X99 主機板。優點是核心多、記憶體大、價格低；缺點是 DDR3 頻寬較低、單核性能一般。

對 LLM 推理來說：
- **DDR3 1600 的頻寬約 25.6 GB/s**（雙通道），MoE 模型的 expert 層放在 CPU 記憶體時會受影響
- **10 核 20 執行緒** 經綽有餘，llama.cpp 的最佳 threads 數通常在 4~8
- **64 GB RAM** 足夠載入整個 20GB 模型 + KV cache，不會 swap

如果你用的是 Xeon E5-2666 v3 或類似的 E5 v3 系列，這份指南的參數可以直接套用。

---

## 根本問題：RDNA2 vs Polaris 的 Vulkan 差異

### RX 580 (Polaris) 需要 GGML_VK_ALLOW_GRAPHICS_QUEUE=1

RX 580 的 Vulkan queue family 有個 bug：llama.cpp 預設避開含 GRAPHICS 的 QF0，選 QF1 作為 compute queue，但 AMD Polaris 驅動在 QF1 上會直接 segfault。

解法：`GGML_VK_ALLOW_GRAPHICS_QUEUE=1` 強制用 QF0。

### RX 6600 (RDNA2) 不需要，設了反而有害

RDNA2 架構的 Vulkan queue family 正常運作，有專屬的 compute queue，不需要這個 workaround。

實測數據：

| 設定 | GGML_VK_ALLOW_GRAPHICS_QUEUE | decode t/s |
|:-----|:----------------------------:|:----------:|
| 沒設 | — | **17.24** |
| 設了 | 1 | **13.89** ← 慢 20% |

**結論：如果你是 Polaris 卡（RX 580/590），必須設。如果你是 RDNA2+（RX 6600/6700/6800/6900），不要設。**

---

## 最佳參數

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

### 參數說明

| 參數 | 值 | 為什麼 |
|:-----|:---|:-------|
| `-ngl 99` | 全部層 offload 到 GPU | 能放 GPU 的都放 GPU |
| `-t 8` | 8 個 CPU threads | 測試 4/6/8/10，**8 最佳**（18.6 t/s） |
| `-c 32768` | 32K context | 配合 q8_0 KV cache 穩定運行 |
| `-fa on` | Flash Attention | **必須開**，否則 KV cache 隨 prompt 線性增長 |
| `--cache-type-k q8_0` | KV cache 量化 | 比 f16 省一半 VRAM |
| `--cache-type-v q8_0` | 同上 | 同上 |
| `--n-cpu-moe 30` | 226 個 expert 在 GPU | 8GB VRAM 的甜蜜點 |
| `--no-mmap` | 不用 mmap | 避免 overhead |
| `-fit off` | 不自動調整 | 保持穩定 |

### 關於 `--n-cpu-moe`

這個參數決定「多少個 MoE expert 放在 CPU 上」：
- `--n-cpu-moe 30` = 30 個 expert 在 CPU，226 個在 GPU
- 越少 expert 在 GPU → decode 越快，但 VRAM 越吃緊
- 8GB VRAM 下，30 是甜蜜點（VRAM 約用 6.7 GB）

---

## `-t` (threads) 調校實測

這是影響最大的參數之一。

| -t | decode t/s | vs 最佳 |
|:--:|:----------:|:-------:|
| 4 | 17.39 | -7% |
| 6 | 18.55 | -0.4% |
| **8** | **18.63** | **最佳** |
| 10 | 17.00 | -9% |

**結論：-t 8 是 Xeon E5-2666 v3 的最佳值。** 超過 8 會因為 CPU contention 反而變慢。

> 注意：不同 CPU 的最佳 -t 值不同。如果你用的是其他 CPU，建議自己測一下 4/6/8/10。

---

## 關於 tg256 的效能異常

測試中發現一個 llama.cpp Vulkan 後端的怪癖：

| 生成長度 | decode t/s |
|:--------:|:----------:|
| tg64 | 17.21 |
| tg96 | 17.17 |
| tg128 | 17.29 |
| tg160 | 17.18 |
| tg192 | 17.18 |
| tg224 | 17.09 |
| **tg256** | **10.04** ← 暴跌 |
| tg288 | 17.30 ← 恢復 |
| tg320 | 17.19 |

**只有 tg256 會掉速**，其他長度全部正常。這是 llama.cpp Vulkan 後端在 RDNA2 上的 boundary effect，不是你的設定問題。

日常使用影響不大（聊天回覆通常不會剛好 256 token），但如果你發現某次回覆特別慢，可能就是觸發了這個 bug。

---

## 顯卡比較：RDNA2 vs Polaris

| 特性 | RX 580 (Polaris) | RX 6600 (RDNA2) |
|:-----|:-----------------|:----------------|
| VRAM | 8 GB GDDR5 | 8 GB GDDR6 |
| 記憶體頻寬 | ~224 GB/s | 224 GB/s |
| fp16 支援 | ❌ 無硬體支援 | ✅ 硬體加速 |
| int dot product | ❌ | ✅ |
| Matrix cores | ❌ | ❌ |
| Vulkan compute queue | 有 bug（需 workaround） | 正常 |
| 最佳 -t | 4 | 8 |
| 需要 GGML_VK_ALLOW_GRAPHICS_QUEUE | ✅ 必須 | ❌ 不要設 |
| Qwen3.6-35B decode | 16.3 t/s | 18.6 t/s |

RDNA2 的 fp16 和 int dot product 硬體支援是主要優勢，讓量化模型的運算效率更高。

---

## 快速開始

### 1. 下載 llama.cpp Vulkan build

```bash
# 從 GitHub releases 下載 Vulkan 版本
# https://github.com/ggml-org/llama.cpp/releases
# 選擇 llama-bXXXX-bin-win-vulkan-x64.zip
```

### 2. 確認 GPU 偵測

```bash
llama-server.exe --list-devices
# 應顯示：Vulkan0: AMD Radeon RX 6600 (8176 MiB)
```

### 3. 下載模型

```bash
# Qwen3.6-35B-A3B Q4_K_M（約 20GB）
# 從 HuggingFace 下載 GGUF 格式
```

### 4. 啟動 Server

```bash
llama-server.exe ^
  -m Qwen3.6-35B-A3B-Q4_K_M.gguf ^
  -ngl 99 --device Vulkan0 -t 8 ^
  -c 32768 -fa on ^
  --cache-type-k q8_0 --cache-type-v q8_0 ^
  -fit off --no-mmap ^
  --n-cpu-moe 30 --port 8080
```

### 5. 開啟瀏覽器

```
http://localhost:8080
```

---

## 已知限制

1. 8GB VRAM 限制：無法把全部 256 個 expert 放在 GPU，需靠 `--n-cpu-moe` 分流
2. tg256 效能異常：llama.cpp Vulkan 後端的已知怪癖
3. DDR3 頻寬瓶頸：X99 + E5-2666 v3 的 DDR3 頻寬會影響 CPU expert 的速度
4. RDNA2 無 matrix cores：不像 RDNA3 / CDNA 有專屬矩陣運算單元

---

## 相關專案

- [castlen3/rx580-llamacpp-vulkan-guide](https://github.com/castlen3/rx580-llamacpp-vulkan-guide) — RX 580 2048SP 同模型優化指南
- [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) — llama.cpp 本體

---

## 測試日期

2026-06-07

---

*如果這份指南對你有幫助，歡迎 star ⭐ 讓更多人看到！*
