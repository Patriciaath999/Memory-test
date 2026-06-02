#!/bin/bash
#==============================================================================
# minimap2 Per-Function Profiling: Backend Stall & Page Walk Hotspots
#
# 目的：
#   找出哪些函式貢獻最多 backend stall 與 page table walk
#   為未來 madvise(MADV_HUGEPAGE) 改動定位精確目標
#
# 與 baseline 對照原則：
#   - 同樣 THP=never（控制變因一致）
#   - 同樣 cold start、numactl --interleave=all、-t 48
#   - 同樣 reference / query
#   - 唯一差別：用 perf record 取樣（會有 ~2.5% overhead，這是 perf record 本質）
#
# 注意：
#   - 每次 run 只能 record 一個 event（perf record 不能同時 multiplex 多 event 還保證精度）
#   - 跑 2 個 event × 1 次（不用 3 次，因為 hotspot ranking 通常穩定）
#   - 跑完用 perf report 輸出 top symbol，存檔
#==============================================================================

set -u

EXPDIR="exp_perfrecord_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$EXPDIR" && cd "$EXPDIR"

REF="../GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz"
QRY="../GCA_018852605.2_Q100_hg002v1.0.1.pat_genomic.fna.gz"
THREADS=48

#------------------------------------------------------------------------------
# Step 0：系統環境快照
#------------------------------------------------------------------------------
{
    echo "### Date"
    date
    echo ""
    echo "### Hardware"
    lscpu | head -20
    echo ""
    echo "### THP setting (will be forced to never)"
    cat /sys/kernel/mm/transparent_hugepage/enabled
    echo ""
    echo "### minimap2"
    minimap2 --version
    echo ""
    echo "### perf"
    perf --version
} > system_info.txt 2>&1

#------------------------------------------------------------------------------
# Step 1：強制 THP=never（跟 baseline 對齊）
#------------------------------------------------------------------------------
echo "Setting THP to never..."
sudo sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled"
sudo sh -c "echo never > /sys/kernel/mm/transparent_hugepage/defrag"
cat /sys/kernel/mm/transparent_hugepage/enabled > thp_setting.txt

#------------------------------------------------------------------------------
# Step 2：定義 record 函式
#------------------------------------------------------------------------------
run_perf_record() {
    local event=$1
    local tag=$2

    echo ""
    echo "=========================================="
    echo "=== Profiling event: $event ($tag) ==="
    echo "=========================================="
    echo "$tag started at $(date)" >> experiment.log

    # Cold start
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sleep 5

    # 量測前快照（簡化版）
    grep -E "^(thp_|compact_|pgfault|pgmajfault)" /proc/vmstat > vmstat_before_${tag}.txt

    # === perf record ===
    # -F 99: 取樣率 99Hz（避免跟 100Hz scheduler tick 同步造成 bias）
    # -g:    call graph
    # --call-graph dwarf: 用 DWARF debug info 解析 call stack（比 fp 準）
    # -e:    要 record 的 event
    /usr/bin/time -v -o time_${tag}.txt \
        numactl --interleave=all \
        perf record \
            -F 99 \
            -e $event \
            --call-graph dwarf \
            -o perf_${tag}.data \
            -- minimap2 -t $THREADS -cx asm5 "$REF" "$QRY" \
            > output_${tag}.paf 2> minimap2_stderr_${tag}.txt

    local exit_code=$?
    echo "minimap2 exit: $exit_code" >> experiment.log

    # 量測後快照
    grep -E "^(thp_|compact_|pgfault|pgmajfault)" /proc/vmstat > vmstat_after_${tag}.txt
    diff vmstat_before_${tag}.txt vmstat_after_${tag}.txt > vmstat_diff_${tag}.txt

    # === 生成 perf report（純文字、固定格式）===
    # By symbol 排序
    perf report -i perf_${tag}.data \
        --sort=symbol \
        --stdio \
        --percent-limit 0.5 \
        > report_${tag}_by_symbol.txt 2>&1

    # By function with call graph
    perf report -i perf_${tag}.data \
        --sort=symbol,dso \
        --stdio \
        -g graph,0.5,caller \
        --percent-limit 0.5 \
        > report_${tag}_with_callgraph.txt 2>&1

    # Top 20 摘要（給人類快速看）
    echo "=== Top 20 hotspots for $event ===" > top20_${tag}.txt
    grep -E "^\s+[0-9]+\.[0-9]+%" report_${tag}_by_symbol.txt | head -20 >> top20_${tag}.txt

    ls -lh perf_${tag}.data output_${tag}.paf >> experiment.log
    echo "=== $tag finished at $(date) ===" | tee -a experiment.log
}

#------------------------------------------------------------------------------
# Step 3：執行兩個關鍵 event 的 profiling
#------------------------------------------------------------------------------

# Event 1: backend stall（找誰在等記憶體）
run_perf_record "stall_backend" "stall_backend"

# Event 2: l2d_tlb_refill（找誰造成 page table walk）
run_perf_record "l2d_tlb_refill" "page_walk"

#------------------------------------------------------------------------------
# Step 4：恢復 THP 預設
#------------------------------------------------------------------------------
sudo sh -c "echo madvise > /sys/kernel/mm/transparent_hugepage/enabled"

#------------------------------------------------------------------------------
# Step 5：彙整摘要
#------------------------------------------------------------------------------
{
    echo "==========================================="
    echo "Per-Function Profiling Summary"
    echo "Directory: $EXPDIR"
    echo "Completed at $(date)"
    echo "==========================================="
    echo ""
    echo "## Control variables (same as baseline)"
    echo "THP: never"
    echo "Threads: $THREADS"
    echo "NUMA: interleave=all"
    echo "Cold start: yes"
    echo ""
    echo "## Profiling overhead note"
    echo "perf record adds ~2.5% wall time overhead (sampling)."
    echo "This is INHERENT to perf record, not a methodology error."
    echo ""
    echo "==========================================="
    echo "## TOP 20: Backend Stall Hotspots"
    echo "## (Who is the CPU waiting for?)"
    echo "==========================================="
    cat top20_stall_backend.txt 2>/dev/null
    echo ""
    echo "==========================================="
    echo "## TOP 20: Page Table Walk Hotspots"
    echo "## (Who is causing TLB pressure?)"
    echo "==========================================="
    cat top20_page_walk.txt 2>/dev/null
    echo ""
    echo "## Files generated:"
    ls -lh
} > SUMMARY.txt

echo ""
echo "==========================================="
echo "Done. Key outputs:"
echo "  - SUMMARY.txt (quick view)"
echo "  - report_stall_backend_by_symbol.txt"
echo "  - report_page_walk_by_symbol.txt"
echo "  - report_*_with_callgraph.txt (with caller chain)"
echo "==========================================="
