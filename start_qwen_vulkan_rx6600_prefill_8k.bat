@echo off
REM ============================================
REM RX 6600 Vulkan - Qwen3.6-35B-A3B Q4_K_M
REM llama.cpp b9547 | tuned for faster 8K prefill
REM 2026-06-09 real-server test: ~181 -> ~223 tok/s
REM Edit LLAMA_DIR and MODEL before first use
REM ============================================

set LLAMA_DIR=C:\path\to\llama-rx6600-vulkan-b9547
set MODEL=C:\path\to\Qwen3.6-35B-A3B-Q4_K_M.gguf

echo ============================================
echo RX 6600 Vulkan - Qwen3.6-35B-A3B Server
echo ============================================

REM Clear stale processes first so leftover VRAM does not poison the next run
taskkill /F /IM llama-server.exe >nul 2>&1
taskkill /F /IM llama-cli.exe >nul 2>&1
ping 127.0.0.1 -n 3 >nul

"%LLAMA_DIR%\llama-server.exe" ^
  -m "%MODEL%" ^
  -ngl 40 ^
  --device Vulkan0 ^
  -t 8 ^
  -c 32768 ^
  -fa on ^
  --cache-type-k q8_0 ^
  --cache-type-v q4_0 ^
  -fit off ^
  --no-mmap ^
  --n-cpu-moe 30 ^
  -b 4096 ^
  -ub 1024 ^
  --host 0.0.0.0 --port 8080

pause
