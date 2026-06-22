#!/bin/bash
set -e

# === v7: 16 MB ===
cp ~/minimap2/lchain.c.v2 ~/minimap2/lchain.c
sed -i 's/2UL \* LC_HUGE_PAGE_SIZE/8UL * LC_HUGE_PAGE_SIZE/' ~/minimap2/lchain.c
cd ~/minimap2
make clean && make arm_neon=1 aarch64=1
cp minimap2 minimap2.v7_16mb
echo "[run_v7_v8] v7 built: $(md5sum minimap2.v7_16mb)"

cd ~/data
MM2_BIN=/home/nancy/minimap2/minimap2.v7_16mb TAG=v7_16mb bash run_perf_stat_ab.sh

# === v8: 4 MB ===
cp ~/minimap2/lchain.c.v2 ~/minimap2/lchain.c
cd ~/minimap2
make clean && make arm_neon=1 aarch64=1
cp minimap2 minimap2.v8_4mb
echo "[run_v7_v8] v8 built: $(md5sum minimap2.v8_4mb)"

cd ~/data
MM2_BIN=/home/nancy/minimap2/minimap2.v8_4mb TAG=v8_4mb bash run_perf_stat_ab.sh

echo "[run_v7_v8] ALL DONE"
