cd ~/data
EXPDIR="exp_$(date +%Y%m%d_%H%M%S)"
mkdir -p $EXPDIR && cd $EXPDIR

# 1. 記錄系統組態 (證明你的 Baseline 處於純淨狀態)
cat /sys/kernel/mm/transparent_hugepage/enabled > thp_policy.txt
grep -i huge /proc/meminfo >> thp_policy.txt

# 2. 自動執行 3 次的實驗迴圈 (SPEC CPU 規範)
for i in {1..3}; do
    echo "=== Starting Run $i at $(date) ===" | tee -a experiment.log

    # 【變因控制 A】清空 Page Cache，確保每次 I/O 都是 Cold Start，不會越跑越快
    sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches'
    sleep 5 # 讓系統背景 I/O 喘口氣

    # L3 起點
    grep -E "thp|compact|pgfault|pgmajfault" /proc/vmstat > vmstat_before_run${i}.txt

    # L4：跑實驗
    # 【變因控制 B】加入 numactl --interleave=all 避免 48 執行緒在 NUMA 節點間發生不穩定的記憶體競爭
    # 【數據修正 C】改用 perf stat 並加入 TLB 事件，以獲取精確總數來計算誤差
    time numactl --interleave=all perf stat \
        -e l1d_cache_refill,l2d_cache_refill,l1d_tlb_refill,l2d_tlb_refill,dTLB-loads,dTLB-load-misses \
        minimap2 -t 48 -cx asm5 \
        ../GCA_009914755.4_T2T-CHM13v2.0_genomic.fna.gz \
        ../GCA_018852605.2_Q100_hg002v1.0.1.pat_genomic.fna.gz \
        > output_run${i}.paf 2>> perf_stat_run${i}.txt

    # L3 終點
    grep -E "thp|compact|pgfault|pgmajfault" /proc/vmstat > vmstat_after_run${i}.txt
    diff vmstat_before_run${i}.txt vmstat_after_run${i}.txt > vmstat_diff_run${i}.txt

    echo "=== Finished Run $i at $(date) ===" | tee -a experiment.log
done

echo "Done at $(date)" | tee -a experiment.log
ls -lh
