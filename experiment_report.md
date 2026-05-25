# minimap2 mmap Baseline 實驗記錄

> **目標：** 量測 minimap2 在 mmap I/O 模式下，對 T2T-CHM13v2.0 × HG002-pat 進行 asm5 比對時的 L1/L2 cache refill 與 TLB miss 行為，作為後續優化的基準線。

---

## 實驗環境

| 欄位 | 內容 |
|------|------|
| 工具版本 | minimap2 v2.30-r1299-dirty |
| 參考基因組 | GCA_009914755.4 T2T-CHM13v2.0 (25 sequences, 3.117 Gbp) |
| 查詢序列 | GCA_018852605.2 Q100 HG002v1.0.1 pat |
| 比對模式 | `-t 48 -cx asm5` |
| THP 政策 | `madvise`（AnonHugePages = 0 kB） |
| Minimizer 參數 | kmer=19, skip=19, HPC=off |
| Distinct minimizers | 215,125,355（92.06% singletons） |

---

## 實驗概覽

| 欄位 | exp_20260520_123703 | exp_20260523_174033 |
|------|:-------------------:|:-------------------:|
| 日期 | 2026-05-20 | 2026-05-23 |
| 描述 | mmap baseline：perf record L1D cache refill hotspot profiling | mmap baseline：perf stat 多計數器，三次重複量測 |
| Profiling 方式 | `perf record -e l1d_cache_refill` | `perf stat -e l1d_cache_refill,l2d_cache_refill,`<br>`l1d_tlb_refill,l2d_tlb_refill,dTLB-loads,dTLB-load-misses` |
| 執行次數 | 1 | 3 |
| perf samples | 33 M（total 62,310,273 samples recorded） | — |

---

## 執行時間與記憶體

| 指標 | exp_20260520<br>（Run 1） | exp_20260523<br>Run 1 | exp_20260523<br>Run 2 | exp_20260523<br>Run 3 | exp_20260523<br>平均 |
|------|:---:|:---:|:---:|:---:|:---:|
| Real time (s) | 3,260.574 | 3,179.396 | 3,180.639 | 3,180.497 | **3,180.18** |
| CPU time (s) | 9,275.989 | 9,047.752 | 9,047.883 | 9,048.878 | **9,048.17** |
| Elapsed (s) | — | 3,179.834 | 3,181.031 | 3,180.984 | **3,180.62** |
| User (s) | — | 8,954.289 | 8,953.908 | 8,955.476 | **8,954.56** |
| Sys (s) | — | 93.897 | 94.364 | 93.884 | **94.05** |
| Peak RSS (GB) | 29.754 | 29.854 | 29.856 | 29.878 | **29.863** |

> **備註：** exp_20260520 Real time 比 exp_20260523 慢約 80 s（+2.5%），推測為 perf record 本身的 overhead（perf.data 8,147 MB）。

---

## Cache Refill 計數

| 計數器 | exp_20260520<br>（approx. event count） | exp_20260523<br>Run 1 | exp_20260523<br>Run 2 | exp_20260523<br>Run 3 | exp_20260523<br>平均 |
|--------|:---:|:---:|:---:|:---:|:---:|
| L1D cache refill | ~320,752,880,949 | 313,485,656,391 | 313,523,572,214 | 313,603,161,803 | **313,537,463,469** |
| L2D cache refill | N/A（未量測） | 156,895,236,783 | 161,970,789,519 | 158,101,547,700 | **158,989,191,334** |

> **L2D / L1D 比率（exp_20260523 平均）：** 158.99 B / 313.54 B ≈ **50.7%**，即約一半的 L1D miss 會繼續 miss L2D，進而存取 DRAM。

---

## TLB Miss 計數（exp_20260523）

| 計數器 | Run 1 | Run 2 | Run 3 | 平均 |
|--------|:---:|:---:|:---:|:---:|
| L1D TLB refill | 189,331,038,200 | 190,850,042,986 | 188,834,087,559 | **189,671,722,915** |
| L2D TLB refill | 14,805,876,498 | 14,789,953,483 | 14,812,311,075 | **14,802,713,685** |
| dTLB-loads (total) | 4,576,198,172,135 | 4,576,219,240,288 | 4,576,461,095,985 | **4,576,292,836,136** |
| dTLB-load-misses | 189,331,038,200 | 190,850,042,986 | 188,834,087,559 | **189,671,722,915** |
| **dTLB miss rate** | **4.14%** | **4.17%** | **4.13%** | **4.15%** |

> **L1D TLB refill = dTLB-load-misses：** 兩者數值相同，表示 TLB miss 事件與 L1 DTLB refill 事件為同一計數器的不同名稱。L2 TLB refill（≈14.8 B）約為 L1 TLB refill 的 **7.8%**，代表多數 TLB miss 可由 L2 TLB 滿足，不需 page table walk。

---

## Page Fault 統計（vmstat diff）

| 指標 | exp_20260520<br>（Run 1） | exp_20260523<br>Run 1 | exp_20260523<br>Run 2 | exp_20260523<br>Run 3 | exp_20260523<br>平均 |
|------|:---:|:---:|:---:|:---:|:---:|
| pgfault（Δ） | 322,976,822 | 32,462,345 | 32,683,459 | 32,267,690 | **32,471,165** |
| pgmajfault（Δ） | 14 | 152 | 208 | 95 | **152** |

> **exp_20260520 pgfault 為 exp_20260523 的 ~10 倍：** exp_20260520 為首次 cold-cache run，大量 mmap page 尚未載入 page cache；exp_20260523 三次連續執行時 page cache 已預熱，minor fault 大幅減少。pgmajfault（disk I/O fault）反而在 exp_20260523 較高，可能因為連續執行間有部分 page 被回收。

---

## L1D Cache Refill Hotspot（exp_20260520 perf record）

> 以下為 `perf report --stdio -s symbol` 輸出，排序依 L1D cache refill 佔比。

| 排名 | 函式 | L1D cache refill % | 上層呼叫鏈 |
|:---:|------|:---:|------|
| 1 | `mg_lchain_rmq` | **41.70%** | `worker_for → mm_map_frag_core` |
| 1a | `krmq_insert_lc_elem` | 9.41% | `mg_lchain_rmq` |
| 1b | `krmq_rmq_lc_elem` | 7.42% | `mg_lchain_rmq` |
| 1c | `krmq_erase_lc_elem` | 6.77% | `mg_lchain_rmq` |
| 1d | `mg_chain_backtrack` | 5.66% | `mg_lchain_rmq` |
| 2 | `mm_align_skeleton / mm_align1` | **29.98%** | `align_regs → mm_map_frag_core` |
| 2a | `ksw_extd2_sse` | 19.47% | `mm_align_pair → mm_align1` |
| 2b | `collect_long_gaps` | 6.27% | `mm_align1` |
| 2c | `ksw_ll_i16` | 2.14% | `mm_align1` |
| 3 | `mm_set_parent` | **19.51%** | `mm_map_frag_core` |
| 4 | `collect_seed_hits` | **4.34%** | `mm_map_frag_core` |
| 4a | `rs_sort_128x`（遞迴） | 2.02% | `collect_seed_hits` |
| 4b | `mm_collect_matches / mm_idx_get` | 1.79% / 1.55% | `collect_seed_hits` |
| 5 | `compact_a` | **1.13%** | `mm_map_frag_core` |

**三大 hotspot 合計：** `mg_lchain_rmq`（41.70%）+ `mm_align1`（29.98%）+ `mm_set_parent`（19.51%）= **91.19%**

---

## 小結

| 觀察 | 數值 |
|------|------|
| 平均 Real time（exp_20260523） | **3,180 s**（≈ 53 min） |
| L1D cache refill / run | **~313.5 B** |
| L2D cache refill / run | **~159.0 B**（L1D miss 中 ~51% 繼續 miss L2D） |
| dTLB miss rate | **~4.15%** |
| L2 TLB 命中率（佔 L1 TLB miss） | **~92.2%**（僅 7.8% 需 page table walk） |
| 最大 cache refill hotspot | **mg_lchain_rmq 41.7%**（RMQ 資料結構隨機存取） |
| 次大 hotspot | **mm_align1 / ksw_extd2_sse 29.98%**（DP alignment） |

**下一步建議：**
- 針對 `mg_lchain_rmq`（41.7%）的 RMQ 資料結構考慮 cache-oblivious layout 或 prefetch。
- 評估 `mm_set_parent`（19.5%）的存取模式是否可透過資料重排降低 cache miss。
- 開啟 HugePage（THP = always）後重跑，觀察 TLB refill 是否顯著下降（預期可降低 dTLB-load-misses）。
