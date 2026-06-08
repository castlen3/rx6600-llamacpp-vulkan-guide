@echo off
set LLAMA_DIR=C:\Users\castlen3\llama-rx6600-vulkan-b9553
set MODEL=C:\Users\castlen3\.lmstudio\models\unsloth\gemma-4-12b-it-UD-Q4_K_XL.gguf
echo Starting Gemma 4 12B Server on RX 6600 (64K FINAL, ngl 45)...
"%LLAMA_DIR%\llama-server.exe" -m "%MODEL%" -ngl 45 --device Vulkan0 -t 8 -tb 6 -c 65536 -b 512 -ub 256 -fa on --cache-type-k q4_0 --cache-type-v q4_0 -fit off --mmap -np 1 --host 0.0.0.0 --port 8080
pause
