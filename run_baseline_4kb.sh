#!/bin/bash
#==============================================================================
# minimap2 4KB Baseline 實驗腳本（給未來 HugeTLB 實驗組對照用）
#
# 設計目的：
#   建立純 4KB page 的 baseline，未來 minimap2 改 code 加 huge page
#   支援後，這份 baseline 是對照基準。
#
# 控制變因：
#   - THP = never（強制純 4KB，避免 kernel 自動合併 anonymous page）
#   - Cold start（每次清 page cache）
#   - NUMA interleave（避免 48 thread 跨 socket 抖動）
#   - CPU pinning（taskset 固定 thread 落點，避免 SMT-4 競爭隨機性）
#
# 量測（三類）：
#   1. Perf 6 events（零 multiplex）
#      cycles, instructions, stall_backend, stall_frontend,
#      dTLB-load-misses, l2d_tlb_refill
#   2. /proc/meminfo 的 PageTables, SUnreclaim（跑前跑後 diff）
#   3. /proc/[pid]/status 背景 watch（每 10s 抓一次，未來對照用）
#   4. 軟體層：/proc/vmstat（page fault, thp, compact 等）
#==============================================================================

set -u

EXPDIR="exp_baseline_4kb_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$EXPDIR" && cd "$EXPDIR"

REF="../GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz"
QRY="../GCA_018852605.2_Q100_hg002v1.0.1.pat_genomic.fna.gz"
THREADS=48
RUNS=3

# CPU pinning：ThunderX2 是 SMT-4（一個 physical core 4 個 hardware thread）
# 224 logical CPU，2 socket × 28 core × 4 SMT
# 為避免 SMT 競爭，pin 到 48 個獨立 physical core 上（跨 NUMA 平均分配）
# Socket 0: CPU 0-111（28 cores × 4 SMT），取 24 個 physical core 的第一個 SMT thread
# Socket 1: CPU 112-223，取 24 個 physical core 的第一個 SMT thread
# Logical CPU ID 在 SMT-4 機器上的排列方式需要先驗證（用 lscpu -e）
# 安全做法：先用 numactl --interleave=all，不強制 taskset
# 若要更精確，改用：taskset -c 0,4,8,...
CPU_BIND_MODE="numa"  # "numa" or "physical"

PERF_EVENTS="cycles,instructions,stall_backend,stall_frontend,dTLB-load-misses,l2d_tlb_refill"

#------------------------------------------------------------------------------
# Step 0：系統環境快照（一次性）
#------------------------------------------------------------------------------
echo "=== Recording system environment ==="
{
    echo "### Hardware"
    lscpu
    echo ""
    echo "### CPU topology (logical → physical mapping)"
    lscpu -e 2>/dev/null | head -50
    echo ""
    echo "### NUMA topology"
    numactl --hardware
    echo ""
    echo "### THP global setting (will be set to never)"
    cat /sys/kernel/mm/transparent_hugepage/enabled
    cat /sys/kernel/mm/transparent_hugepage/defrag
    echo ""
    echo "### Memory"
    grep -E "MemTotal|MemFree|MemAvailable|PageTables|SUnreclaim|AnonHugePages|HugePages" /proc/meminfo
    echo ""
    echo "### minimap2"
    minimap2 --version
    echo ""
    echo "### perf"
    perf --version
    echo ""
    echo "### Available perf events (filtered)"
    perf list 2>/dev/null | grep -iE "stall|cycle|tlb|cache_refill" | head -30
} > system_info.txt 2>&1

#------------------------------------------------------------------------------
# Step 1：強制 THP=never（控制變因）
#------------------------------------------------------------------------------
echo "Setting THP to never (force 4KB only)..."
sudo sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled"
sudo sh -c "echo never > /sys/kernel/mm/transparent_hugepage/defrag"

# 驗證設定
cat /sys/kernel/mm/transparent_hugepage/enabled > thp_setting.txt
cat /sys/kernel/mm/transparent_hugepage/defrag >> thp_setting.txt
echo "THP enabled: $(cat /sys/kernel/mm/transparent_hugepage/enabled)"
echo "THP defrag:  $(cat /sys/kernel/mm/transparent_hugepage/defrag)"

#------------------------------------------------------------------------------
# Step 2：實驗主迴圈
#------------------------------------------------------------------------------
for i in $(seq 1 $RUNS); do
    tag="run${i}"
    echo ""
    echo "=========================================="
    echo "=== Starting $tag at $(date) ==="
    echo "=========================================="
    echo "$tag started at $(date)" >> experiment.log

    # ===== 變因控制 A：Cold start =====
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sleep 5

    # ===== 量測前快照 =====
    # 1. Perf 軟體層（vmstat：page fault, thp, compact 等）
    grep -E "^(thp_|compact_|pgfault|pgmajfault|pgscan|pgsteal|pswpin|pswpout)" \
        /proc/vmstat > vmstat_before_${tag}.txt

    # 2. 記憶體 metadata（PageTables、SUnreclaim 是核心對照指標）
    grep -E "PageTables|SUnreclaim|SReclaimable|Slab|AnonHugePages|HugePages|MemFree" \
        /proc/meminfo > meminfo_before_${tag}.txt

    # 3. NUMA 分佈
    numastat -m > numastat_before_${tag}.txt 2>/dev/null

    # 4. PSI（memory pressure）
    cat /proc/pressure/memory > psi_before_${tag}.txt 2>/dev/null

    # ===== 變因控制 B：NUMA + CPU 分配 =====
    # 用 numactl --interleave=all 確保記憶體分散到兩個 NUMA node
    NUMACTL_OPTS="--interleave=all"

    # ===== 主量測 =====
    # 啟動 minimap2（背景），同時跑 watch 抓 /proc/[pid]/status
    /usr/bin/time -v -o time_${tag}.txt \
        numactl $NUMACTL_OPTS \
        perf stat -o perf_stat_${tag}.txt \
            -e $PERF_EVENTS \
            minimap2 -t $THREADS -cx asm5 "$REF" "$QRY" \
            > output_${tag}.paf 2> minimap2_stderr_${tag}.txt &

    MINIMAP_PID=$!
    echo "minimap2 PID: $MINIMAP_PID" >> experiment.log

    # 背景 watch /proc/[pid]/status（每 10 秒一筆）
    # 注意：PID 是 numactl 的，要找實際 minimap2 的 child PID
    (
        sleep 3  # 等 minimap2 真的啟動
        # 找 minimap2 的真實 PID（numactl 的 child）
        ACTUAL_PID=$(pgrep -P $MINIMAP_PID -x minimap2 2>/dev/null)
        if [ -z "$ACTUAL_PID" ]; then
            # 如果 numactl 直接 exec 變成 minimap2，PID 就是它本身
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

    # 等 minimap2 跑完
    wait $MINIMAP_PID
    EXIT_CODE=$?
    echo "minimap2 exit code: $EXIT_CODE" >> experiment.log

    # 確保 watch 結束
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

    # ===== 輸出健全性檢查 =====
    wc -l output_${tag}.paf >> experiment.log
    ls -lh output_${tag}.paf >> experiment.log
    echo "=== $tag finished at $(date) ===" | tee -a experiment.log
done

#------------------------------------------------------------------------------
# Step 3：恢復 THP 預設（避免影響後續使用）
#------------------------------------------------------------------------------
sudo sh -c "echo madvise > /sys/kernel/mm/transparent_hugepage/enabled"
echo "THP restored to madvise (system default)"

#------------------------------------------------------------------------------
# Step 4：彙整摘要
#------------------------------------------------------------------------------
{
    echo "==========================================="
    echo "Baseline 4KB Experiment Summary"
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
    echo "## Files generated:"
    ls -lh
} > SUMMARY.txt

echo ""
echo "==========================================="
echo "All done. Output: $EXPDIR"
echo ""
echo "CRITICAL: Check SUMMARY.txt — every perf event must show (100.00%)."
echo "If multiplexing occurred, results will be inaccurate."
echo "==========================================="
