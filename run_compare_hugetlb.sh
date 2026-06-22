cat > ~/data/run_compare_hugetlb_perfrecord.sh << 'EOF'
#!/bin/bash
# A/B perf record: baseline vs hugetlb, by event, with call graph
set -u
cd ~/data
EXPDIR="exp_perfrecord_hugetlb_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$EXPDIR" && cd "$EXPDIR"

REF="../GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz"
QRY="../GCA_018852605.2_Q100_hg002v1.0.1.pat_genomic.fna.gz"
THREADS=48

declare -A BINARIES
BINARIES[baseline]=~/minimap2/minimap2.baseline
BINARIES[hugetlb]=~/minimap2/minimap2.hugetlb

# 系統快照
{
    echo "### Date"; date
    echo "### THP"; cat /sys/kernel/mm/transparent_hugepage/enabled
    echo "### HugePages"; grep -i huge /proc/meminfo
    echo "### Binaries"; md5sum ~/minimap2/minimap2.baseline ~/minimap2/minimap2.hugetlb
} > system_info.txt

run_one() {
    local variant=$1
    local event=$2
    local tag="${variant}_${event}"
    local bin="${BINARIES[$variant]}"

    echo "=== $tag started at $(date) ===" | tee -a experiment.log

    # Cold start
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sleep 5

    grep -E "^(thp_|compact_|pgfault|pgmajfault)" /proc/vmstat > vmstat_before_${tag}.txt

    /usr/bin/time -v -o time_${tag}.txt \
        numactl --interleave=all \
        perf record \
            -F 99 \
            -e $event \
            --call-graph dwarf \
            -o perf_${tag}.data \
            -- $bin -t $THREADS -cx asm5 "$REF" "$QRY" \
            > output_${tag}.paf 2> minimap2_stderr_${tag}.txt

    grep -E "^(thp_|compact_|pgfault|pgmajfault)" /proc/vmstat > vmstat_after_${tag}.txt
    diff vmstat_before_${tag}.txt vmstat_after_${tag}.txt > vmstat_diff_${tag}.txt

    # 生 report
    perf report -i perf_${tag}.data --sort=symbol --stdio --percent-limit 0.5 \
        > report_${tag}_by_symbol.txt 2>&1
    perf report -i perf_${tag}.data --sort=symbol,dso --stdio -g graph,0.5,caller --percent-limit 0.5 \
        > report_${tag}_with_callgraph.txt 2>&1

    echo "=== Top 20 for $tag ===" > top20_${tag}.txt
    grep -E "^\s+[0-9]+\.[0-9]+%" report_${tag}_by_symbol.txt | head -20 >> top20_${tag}.txt

    echo "=== $tag finished at $(date) ===" | tee -a experiment.log
}

# 跑 4 種組合：baseline/hugetlb × l1d/l2d
for variant in baseline hugetlb; do
    for event in l1d_cache_refill l2d_cache_refill l2d_tlb_refill; do
        run_one $variant $event
    done
done

# Summary
{
    echo "================================================"
    echo "perf record A/B summary (hugetlb vs baseline)"
    echo "Directory: $EXPDIR"
    echo "================================================"
    for event in l1d_cache_refill l2d_cache_refill l2d_tlb_refill; do
        echo ""
        echo "=========================================="
        echo "## EVENT: $event"
        echo "=========================================="
        echo ""
        echo "--- BASELINE TOP 20 ---"
        cat top20_baseline_${event}.txt 2>/dev/null
        echo ""
        echo "--- HUGETLB TOP 20 ---"
        cat top20_hugetlb_${event}.txt 2>/dev/null
    done
    echo ""
    echo "## Files"
    ls -lh
} > SUMMARY.txt

echo "Done. See SUMMARY.txt"
EOF

chmod +x ~/data/run_compare_hugetlb_perfrecord.sh
