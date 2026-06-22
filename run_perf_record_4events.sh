#!/bin/bash
# 腳本名稱：run_perf_record_4events.sh
# 目的：針對四個核心硬體事件，分別進行獨立的冷啟動 Profiling
set -u

EXPDIR="exp_perfrecord_4events_$(date +%Y%m%d_%H%M%S)"
BIN_PATH="$HOME/minimap2/minimap2.v10_v1_outerpf"
REF="../GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz"
QRY="../GCA_018852605.2_Q100_hg002v1.0.1.pat_genomic.fna.gz"
THREADS=48

mkdir -p "$EXPDIR" && cd "$EXPDIR"

# 採用 ARM 原生硬體事件碼，避免 perf 名稱解析錯誤
EVENTS=(
    "r03" # l1d_cache_refill
    "r17" # l2d_cache_refill
    "r2d" # l2d_tlb_refill
    "r24" # stall_backend
)

echo "=== 開始執行 4 項核心硬體事件 Profiling ===" | tee experiment.log

echo "[*] 解放 PMU 與核心符號權限..." | tee -a experiment.log
sudo sysctl -w kernel.perf_event_paranoid=-1
sudo sysctl -w kernel.kptr_restrict=0

for event in "${EVENTS[@]}"; do
    echo "" | tee -a experiment.log
    echo "==========================================" | tee -a experiment.log
    echo " 正在測量事件 (Raw Code): $event" | tee -a experiment.log
    echo "==========================================" | tee -a experiment.log

    echo "[*] 清除系統快取 (Drop Caches)..."
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sleep 5 

    echo "[*] 開始執行 perf record ($event)..."
    /usr/bin/time -v -o "time_${event}.txt" \
        numactl --interleave=all \
        perf record \
            -F 99 \
            -e "$event" \
            --call-graph dwarf \
            -o "perf_${event}.data" \
            -- $BIN_PATH -t $THREADS -cx asm5 "$REF" "$QRY" \
            > "output_${event}.paf" 2> "stderr_${event}.log"

    echo "[*] 產生報告..."
    perf report -i "perf_${event}.data" --sort=symbol --stdio --percent-limit 0.5 \
        > "report_${event}_by_symbol.txt" 2>&1
    
    perf report -i "perf_${event}.data" --sort=symbol,dso --stdio -g graph,0.5,caller --percent-limit 0.5 \
        > "report_${event}_with_callgraph.txt" 2>&1

    echo "=== Top 20 for $event ===" > "top20_${event}.txt"
    grep -E "^\s+[0-9]+\.[0-9]+%" "report_${event}_by_symbol.txt" | head -20 >> "top20_${event}.txt"

    echo "[V] $event 測量完成！" | tee -a experiment.log
done

{
    echo "================================================"
    echo "4 Events Profiling Summary"
    echo "目錄: $EXPDIR"
    echo "================================================"
    for event in "${EVENTS[@]}"; do
        echo ""
        echo "## 🏆 導致 [ $event ] 最嚴重的 Top 20 函式 🏆 ##"
        cat "top20_${event}.txt" 2>/dev/null
    done
} > SUMMARY.txt

echo "全部跑完了！請直接查看 $EXPDIR/SUMMARY.txt"

