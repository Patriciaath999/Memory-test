#!/bin/bash
#==============================================================================
# minimap2 4KB perf-stat AB Test (parameterized by MM2_BIN / TAG)
#
# 用法：
#   MM2_BIN=~/minimap2/minimap2.baseline TAG=baseline bash run_perf_stat_ab.sh
#   MM2_BIN=~/minimap2/minimap2          TAG=v2       bash run_perf_stat_ab.sh
#
# 控制變因（同舊 baseline 腳本）：
#   - THP = never
#   - Cold start
#   - NUMA interleave=all
#   - 3 次重複，6 個 perf events，零 multiplex
#==============================================================================

set -u

# ===== 可由環境變數覆寫 =====
MM2_BIN="${MM2_BIN:-minimap2}"
TAG="${TAG:-$(basename $MM2_BIN)}"

EXPDIR="exp_perfstat_${TAG}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$EXPDIR" && cd "$EXPDIR"

REF="../GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz"
QRY="../GCA_018852605.2_Q100_hg002v1.0.1.pat_genomic.fna.gz"
THREADS=48
RUNS=1

PERF_EVENTS="cycles,instructions,stall_backend,l1d_cache_refill,l2d_cache_refill,l2d_tlb_refill"

#------------------------------------------------------------------------------
# Step 0：系統環境快照
#------------------------------------------------------------------------------
echo "=== Recording system environment ==="
{
    echo "### Date"; date
    echo ""
    echo "### Binary under test"
    echo "MM2_BIN = $MM2_BIN"
    echo "TAG     = $TAG"
    md5sum "$MM2_BIN" 2>/dev/null || echo "(binary not found?)"
    echo ""
    echo "### Hardware"
    lscpu | head -20
    echo ""
    echo "### THP global setting (will be set to never)"
    cat /sys/kernel/mm/transparent_hugepage/enabled
    echo ""
    echo "### HugePages"
    grep -i huge /proc/meminfo
    echo ""
    echo "### Memory"
    grep -E "MemTotal|MemFree|MemAvailable|PageTables" /proc/meminfo
    echo ""
    echo "### minimap2 (the binary under test)"
    $MM2_BIN --version 2>/dev/null
    echo ""
    echo "### perf"
    perf --version
} > system_info.txt 2>&1

#------------------------------------------------------------------------------
# Step 1：強制 THP=never
#------------------------------------------------------------------------------
echo "Setting THP to never..."
sudo sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled"
sudo sh -c "echo never > /sys/kernel/mm/transparent_hugepage/defrag"
cat /sys/kernel/mm/transparent_hugepage/enabled > thp_setting.txt

#------------------------------------------------------------------------------
# Step 2：實驗主迴圈
#------------------------------------------------------------------------------
for i in $(seq 1 $RUNS); do
    tag="run${i}"
    echo ""
    echo "=========================================="
    echo "=== [$TAG] Starting $tag at $(date) ==="
    echo "=========================================="
    echo "[$TAG] $tag started at $(date)" >> experiment.log

    # Cold start
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sleep 5

    # ===== 量測前快照 =====
    grep -E "^(thp_|compact_|pgfault|pgmajfault|pgscan|pgsteal|pswpin|pswpout)" \
        /proc/vmstat > vmstat_before_${tag}.txt
    grep -E "PageTables|SUnreclaim|SReclaimable|Slab|AnonHugePages|HugePages|MemFree" \
        /proc/meminfo > meminfo_before_${tag}.txt
    numastat -m > numastat_before_${tag}.txt 2>/dev/null
    cat /proc/pressure/memory > psi_before_${tag}.txt 2>/dev/null

    # ===== 主量測（使用 $MM2_BIN）=====
    /usr/bin/time -v -o time_${tag}.txt \
        numactl --interleave=all \
        perf stat -o perf_stat_${tag}.txt \
            -e $PERF_EVENTS \
            $MM2_BIN -t $THREADS -cx asm5 "$REF" "$QRY" \
            > output_${tag}.paf 2> minimap2_stderr_${tag}.txt &

    MINIMAP_PID=$!
    echo "PID: $MINIMAP_PID" >> experiment.log

    # 背景 watch /proc/[pid]/status
    (
        sleep 3
        ACTUAL_PID=$(pgrep -P $MINIMAP_PID -x minimap2 2>/dev/null)
        if [ -z "$ACTUAL_PID" ]; then
            ACTUAL_PID=$MINIMAP_PID
        fi
        echo "Watching actual PID: $ACTUAL_PID" >> experiment.log

        while kill -0 $ACTUAL_PID 2>/dev/null; do
            echo "--- $(date +%H:%M:%S) ---" >> pid_status_${tag}.log
            grep -E "VmRSS|VmPTE|VmPMD|VmSize|HugetlbPages|AnonHugePages|Threads" \
                /proc/$ACTUAL_PID/status 2>/dev/null >> pid_status_${tag}.log
            sleep 10
        done
    ) &
    WATCH_PID=$!

    wait $MINIMAP_PID
    EXIT_CODE=$?
    echo "exit code: $EXIT_CODE" >> experiment.log

    kill $WATCH_PID 2>/dev/null
    wait $WATCH_PID 2>/dev/null

    # ===== 量測後快照 =====
    grep -E "^(thp_|compact_|pgfault|pgmajfault|pgscan|pgsteal|pswpin|pswpout)" \
        /proc/vmstat > vmstat_after_${tag}.txt
    diff vmstat_before_${tag}.txt vmstat_after_${tag}.txt > vmstat_diff_${tag}.txt

    grep -E "PageTables|SUnreclaim|SReclaimable|Slab|AnonHugePages|HugePages|MemFree" \
        /proc/meminfo > meminfo_after_${tag}.txt
    diff meminfo_before_${tag}.txt meminfo_after_${tag}.txt > meminfo_diff_${tag}.txt

    numastat -m > numastat_after_${tag}.txt 2>/dev/null
    cat /proc/pressure/memory > psi_after_${tag}.txt 2>/dev/null

    # ===== Multiplex sanity check =====
    echo "--- Counter coverage check for $tag ---" >> multiplex_check.log
    grep -E "[0-9]+\.[0-9]+%" perf_stat_${tag}.txt >> multiplex_check.log 2>/dev/null || true
    echo "" >> multiplex_check.log

    wc -l output_${tag}.paf >> experiment.log
    ls -lh output_${tag}.paf >> experiment.log
    echo "[$TAG] $tag finished at $(date)" | tee -a experiment.log
done

#------------------------------------------------------------------------------
# Step 3：恢復 THP
#------------------------------------------------------------------------------
sudo sh -c "echo madvise > /sys/kernel/mm/transparent_hugepage/enabled"
echo "THP restored to madvise"

#------------------------------------------------------------------------------
# Step 4：彙整摘要
#------------------------------------------------------------------------------
{
    echo "==========================================="
    echo "perf-stat AB-test Summary"
    echo "TAG     = $TAG"
    echo "MM2_BIN = $MM2_BIN"
    echo "Directory: $EXPDIR"
    echo "Completed at $(date)"
    echo "==========================================="
    echo ""
    echo "## Configuration"
    echo "THP: never (forced 4KB)"
    echo "Threads: $THREADS"
    echo "NUMA: interleave=all"
    echo "Runs: $RUNS"
    echo ""
    echo "## Perf events (should all show 100.00% coverage)"
    echo "$PERF_EVENTS"
    echo ""
    echo "## Counter coverage check:"
    cat multiplex_check.log 2>/dev/null || echo "(no log)"
    echo ""
    echo "## Per-run perf stat output:"
    for i in $(seq 1 $RUNS); do
        echo "--- run${i} ---"
        cat perf_stat_run${i}.txt 2>/dev/null
        echo ""
    done
    echo ""
    echo "## Files generated:"
    ls -lh
} > SUMMARY.txt

echo ""
echo "==========================================="
echo "All done. Output: $EXPDIR"
echo "CRITICAL: Check SUMMARY.txt — every perf event must show (100.00%)."
echo "==========================================="
