#!/bin/bash
set -u
MM2_BIN="${MM2_BIN:-minimap2}"
TAG="${TAG:-$(basename $MM2_BIN)}"
EXPDIR="exp_perfstat_${TAG}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$EXPDIR" && cd "$EXPDIR"
REF="../GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz"
QRY="../GCA_018852605.2_Q100_hg002v1.0.1.pat_genomic.fna.gz"
THREADS=48
RUNS=1
PERF_EVENTS="cycles,instructions,stall_backend,l1d_cache_refill,l2d_cache_refill,l2d_tlb_refill"
echo "=== Recording system environment ==="
{
    echo "### Date"; date
    echo "### Binary under test"
    echo "MM2_BIN = $MM2_BIN"
    echo "TAG     = $TAG"
    md5sum "$MM2_BIN" 2>/dev/null || echo "(binary not found?)"
    echo "### THP global setting (will be set to never)"
    cat /sys/kernel/mm/transparent_hugepage/enabled
    echo "### HugePages"
    grep -i huge /proc/meminfo
    echo "### minimap2 (the binary under test)"
    $MM2_BIN --version 2>/dev/null
    echo "### perf"
    perf --version
} > system_info.txt 2>&1
echo "Setting THP to never..."
sudo sh -c "echo never > /sys/kernel/mm/transparent_hugepage/enabled"
sudo sh -c "echo never > /sys/kernel/mm/transparent_hugepage/defrag"
cat /sys/kernel/mm/transparent_hugepage/enabled > thp_setting.txt
for i in $(seq 1 $RUNS); do
    tag="run${i}"
    echo "=== [$TAG] Starting $tag at $(date) ==="
    echo "[$TAG] $tag started at $(date)" >> experiment.log
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sleep 5
    grep -E "^(thp_|compact_|pgfault|pgmajfault)" /proc/vmstat > vmstat_before_${tag}.txt
    grep -E "PageTables|SUnreclaim|AnonHugePages|HugePages|MemFree" /proc/meminfo > meminfo_before_${tag}.txt
    /usr/bin/time -v -o time_${tag}.txt \
        numactl --interleave=all \
        perf stat -o perf_stat_${tag}.txt \
            -e $PERF_EVENTS \
            $MM2_BIN -t $THREADS -cx asm5 "$REF" "$QRY" \
            > output_${tag}.paf 2> minimap2_stderr_${tag}.txt
    grep -E "^(thp_|compact_|pgfault|pgmajfault)" /proc/vmstat > vmstat_after_${tag}.txt
    diff vmstat_before_${tag}.txt vmstat_after_${tag}.txt > vmstat_diff_${tag}.txt
    grep -E "PageTables|SUnreclaim|AnonHugePages|HugePages|MemFree" /proc/meminfo > meminfo_after_${tag}.txt
    echo "--- Counter coverage check for $tag ---" >> multiplex_check.log
    grep -E "[0-9]+\.[0-9]+%" perf_stat_${tag}.txt >> multiplex_check.log 2>/dev/null || true
    echo "" >> multiplex_check.log
    wc -l output_${tag}.paf >> experiment.log
    echo "[$TAG] $tag finished at $(date)" | tee -a experiment.log
done
sudo sh -c "echo madvise > /sys/kernel/mm/transparent_hugepage/enabled"
echo "THP restored to madvise"
{
    echo "perf-stat Summary: TAG=$TAG MM2_BIN=$MM2_BIN"
    echo "Completed at $(date)"
    echo "PERF_EVENTS=$PERF_EVENTS"
    echo "## Counter coverage check:"
    cat multiplex_check.log 2>/dev/null
    for i in $(seq 1 $RUNS); do
        echo "--- run${i} ---"
        cat perf_stat_run${i}.txt 2>/dev/null
    done
    echo "## Files:"; ls -lh
} > SUMMARY.txt
echo "All done. Output: $EXPDIR"
