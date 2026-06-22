#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <assert.h>
#include <time.h>

/* ===== 1. 基礎結構與 Minimap2 模擬定義 ===== */
typedef struct {
    uint64_t x, y;
} mm128_t;

typedef struct lc_elem_s {
    int32_t y;
    int64_t i;
    double pri;
    struct lc_elem_s *left, *right, *p;
    size_t cnt;
} lc_elem_t;

/* ===== 2. 獨立模擬：從二進位檔案載入 Dump 資料 ===== */
mm128_t *load_dump_data(const char *filename, int64_t *out_n) {
    FILE *fp = fopen(filename, "rb");
    if (!fp) {
        perror("無法開啟 Dump 檔案");
        return NULL;
    }

    int64_t n = 0;
    if (fread(&n, sizeof(int64_t), 1, fp) != 1) {
        fprintf(stderr, "讀取 n 失敗\n");
        fclose(fp);
        return NULL;
    }

    mm128_t *a = (mm128_t *)malloc(n * sizeof(mm128_t));
    if (!a) {
        fprintf(stderr, "記憶體配置失敗 (n = %ld)\n", (long)n);
        fclose(fp);
        return NULL;
    }

    size_t read_cnt = fread(a, sizeof(mm128_t), n, fp);
    if (read_cnt != (size_t)n) {
        fprintf(stderr, "預期讀取 %ld 筆，實際只讀到 %zu 筆\n", (long)n, read_cnt);
        free(a);
        fclose(fp);
        return NULL;
    }

    fclose(fp);
    *out_n = n;
    return a;
}

/* ===== 3. 小型測試的主程式主體 ===== */
int main(int argc, char *argv[]) {
    if (argc != 2) {
        fprintf(stderr, "使用方法: %s <lchain_dump_X_nX.bin>\n", argv[0]);
        return 1;
    }

    int64_t n = 0;
    printf("正在載入測試資料: %s ...\n", argv[1]);
    mm128_t *a = load_dump_data(argv[1], &n);
    
    if (!a) {
        return 1;
    }

    printf("成功載入！測試基準資料量 n = %ld\n", (long)n);
    printf("第一個元素: x = %lu, y = %lu\n", (unsigned long)a[0].x, (unsigned long)a[0].y);
    printf("最後一個元素: x = %lu, y = %lu\n", (unsigned long)a[n-1].x, (unsigned long)a[n-1].y);

    /* ===== 4. 效能評測區塊 (微秒級計時) ===== */
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);

    size_t fake_alloc_cnt = n; 
    printf("\n[測試] 模擬原始分配行為中 (配置 %zu 個 lc_elem_t)...\n", fake_alloc_cnt);
    
    lc_elem_t **test_pool = (lc_elem_t **)malloc(fake_alloc_cnt * sizeof(lc_elem_t *));
    for (size_t i = 0; i < fake_alloc_cnt; ++i) {
        test_pool[i] = (lc_elem_t *)malloc(sizeof(lc_elem_t));
        test_pool[i]->y = (int32_t)i;
    }
    for (size_t i = 0; i < fake_alloc_cnt; ++i) {
        free(test_pool[i]);
    }
    free(test_pool);

    clock_gettime(CLOCK_MONOTONIC, &end);
    double elapsed = (end.tv_sec - start.tv_sec) + (end.tv_nsec - start.tv_nsec) / 1e9;
    printf("模擬執行花費時間: %.6f 秒\n", elapsed);

    free(a);
    printf("測試結束，記憶體已釋放。\n");
    return 0;
}
