#ifndef KALLOC_H
#define KALLOC_H

#include <stddef.h>

typedef struct {
	size_t capacity, available, n_blocks, n_cores, largest;
} km_stat_t;

#ifdef __cplusplus
extern "C" {
#endif

void *km_init(void);
void *km_init2(void *km_par, size_t min_core_size);
void *km_init_hugepages(void);   /* anonymous 2MiB HugeTLB pages; Linux only */
void  km_destroy(void *km);

void *kmalloc(void *km, size_t size);
void  kfree(void *km, void *ptr);
void *kcalloc(void *km, size_t count, size_t size);
void *krealloc(void *km, void *ptr, size_t size);
void *krelocate(void *km, void *ptr, size_t n_bytes);

void km_stat(const void *km, km_stat_t *s);
void km_stat_print(const void *km);

#ifdef __cplusplus
}
#endif

#endif /* KALLOC_H */
