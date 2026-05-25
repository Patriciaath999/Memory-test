#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "kalloc.h"

/* ------------------------------------------------------------------ *
 * Hugepage support (Linux HugeTLB, anonymous 2 MiB pages)            *
 *                                                                     *
 * Motivation: HugeTLB Vmemmap Optimization (HVO,                     *
 * CONFIG_HUGETLB_PAGE_OPTIMIZE_VMEMMAP=y) lets the kernel reclaim    *
 * the struct-page array inside each hugepage.  On a 128 GiB system   *
 * this saves ~1.75 GiB of kernel memory, which can be the difference *
 * between fitting a large index and OOM.                              *
 *                                                                     *
 * Transparent Huge Pages (MADV_HUGEPAGE / THP) do NOT help here:     *
 * THP remaps existing 4 KiB pages under a 2 MiB entry for TLB        *
 * efficiency but keeps the struct-page array intact.  Only explicit  *
 * HugeTLB pool allocation with HVO addresses the metadata cost.      *
 *                                                                     *
 * Usage:                                                              *
 *   # reserve pool (no reboot needed for 2 MiB pages)                *
 *   sudo sysctl -w vm.nr_hugepages=<N>   # N * 2 MiB >= index size   *
 *   sudo sysctl -w vm.hugetlb_optimize_vmemmap=1   # for HVO benefit *
 *                                                                     *
 * The hugepage path is taken only when km_init_hugepages() is used   *
 * and is compiled in only on Linux, so there is zero cost on other   *
 * platforms or when the flag is not set.                              *
 * ------------------------------------------------------------------ */

#ifdef __linux__
#include <sys/mman.h>
#include <errno.h>

/* MAP_HUGETLB / MAP_HUGE_SHIFT may not be in older glibc headers */
#ifndef MAP_HUGETLB
#define MAP_HUGETLB 0x40000
#endif
#ifndef MAP_HUGE_SHIFT
#define MAP_HUGE_SHIFT 26
#endif

#define HUGEPAGE_SIZE  (2UL << 20)       /* 2 MiB */
#define HUGEPAGE_SHIFT 21
#define MAP_HUGE_2MB   (HUGEPAGE_SHIFT << MAP_HUGE_SHIFT)
#endif /* __linux__ */

/* In kalloc, a *core* is a large chunk of contiguous memory. Each core is
 * associated with a master header, which keeps the size of the current core
 * and the pointer to next core. Kalloc allocates small *blocks* of memory from
 * the cores and organizes free memory blocks in a circular single-linked list.
 *
 * In the following diagram, "@" stands for the header of a free block (of type
 * header_t), "#" for the header of an allocated block (of type size_t), "-"
 * for free memory, and "+" for allocated memory.
 *
 * master        This region is core 1.          master           This region is core 2.
 *      |
 *      *@-------#++++++#++++++++++++@--------        *@----------#++++++++++++#+++++++@------------
 *       |                           |                 |                               |
 *       p=p->ptr->ptr->ptr->ptr     p->ptr            p->ptr->ptr                     p->ptr->ptr->ptr
 */
typedef struct header_t {
	size_t size;
	struct header_t *ptr;
} header_t;

typedef struct {
	void *par;
	size_t min_core_size;
	int use_hugepages;           /* 1 = allocate cores via HugeTLB mmap */
	header_t base, *loop_head, *core_head; /* base is a zero-sized block always kept in the loop */
} kmem_t;

static void panic(const char *s)
{
	fprintf(stderr, "%s\n", s);
	abort();
}

void *km_init2(void *km_par, size_t min_core_size)
{
	kmem_t *km;
	km = (kmem_t*)kcalloc(km_par, 1, sizeof(kmem_t));
	km->par = km_par;
	if (km_par) km->min_core_size = min_core_size > 0? min_core_size : ((kmem_t*)km_par)->min_core_size - 2;
	else km->min_core_size = min_core_size > 0? min_core_size : 0x80000;
	return (void*)km;
}

void *km_init(void) { return km_init2(0, 0); }

/*
 * km_init_hugepages - create a top-level pool backed by 2 MiB HugeTLB pages.
 *
 * Each core requested from the OS will be allocated with:
 *   mmap(MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_HUGE_2MB | MAP_POPULATE)
 *
 * MAP_POPULATE forces the kernel to fill the hugepage pool at mmap() time,
 * so a pool-exhaustion failure surfaces as a clean ENOMEM with a diagnostic
 * rather than a SIGBUS during later access.
 *
 * On non-Linux platforms this function falls back silently to km_init().
 */
void *km_init_hugepages(void)
{
	kmem_t *km = (kmem_t*)km_init();
#ifdef __linux__
	((kmem_t*)km)->use_hugepages = 1;
#endif
	return km;
}

void km_destroy(void *_km)
{
	kmem_t *km = (kmem_t*)_km;
	void *km_par;
	int use_hp;
	header_t *p, *q;
	if (km == NULL) return;
	km_par = km->par;
	use_hp = km->use_hugepages;
	for (p = km->core_head; p != NULL;) {
		q = p->ptr;   /* read next pointer BEFORE freeing p */
#ifdef __linux__
		if (use_hp && km_par == NULL) {
			/* p points to the start of the mmap'd region;
			 * p->size is the region size in header_t units (set in morecore
			 * and never modified thereafter). */
			size_t bytes = (size_t)p->size * sizeof(header_t);
			munmap(p, bytes);
		} else
#endif
		{
			kfree(km_par, p);
		}
		p = q;
	}
	/* km itself was allocated with calloc/kmalloc (never mmap), so kfree is
	 * always correct here. */
	kfree(km_par, km);
}

static header_t *morecore(kmem_t *km, size_t nu)
{
	header_t *q;
	size_t bytes, *p;
	nu = (nu + 1 + (km->min_core_size - 1)) / km->min_core_size * km->min_core_size; /* the first +1 for core header */
	bytes = nu * sizeof(header_t);

#ifdef __linux__
	if (km->use_hugepages && km->par == NULL) {
		/* Round up to the next 2 MiB boundary so mmap never gets a partial
		 * hugepage (the kernel would reject it with EINVAL). */
		bytes = (bytes + HUGEPAGE_SIZE - 1) & ~(HUGEPAGE_SIZE - 1);
		nu = bytes / sizeof(header_t);

		q = (header_t*)mmap(NULL, bytes,
		                    PROT_READ | PROT_WRITE,
		                    MAP_PRIVATE | MAP_ANONYMOUS | MAP_HUGETLB | MAP_HUGE_2MB | MAP_POPULATE,
		                    -1, 0);
		if (q == MAP_FAILED) {
			fprintf(stderr,
			        "[morecore] HugeTLB allocation of %zu MiB failed: %s\n"
			        "  Make sure the pool is large enough:\n"
			        "    sudo sysctl -w vm.nr_hugepages=%zu\n"
			        "  To enable vmemmap reclamation (HVO):\n"
			        "    sudo sysctl -w vm.hugetlb_optimize_vmemmap=1\n",
			        bytes >> 20, strerror(errno),
			        (bytes + HUGEPAGE_SIZE - 1) / HUGEPAGE_SIZE);
			abort();
		}
	} else
#endif
	{
		q = (header_t*)kmalloc(km->par, bytes);
		if (!q) panic("[morecore] insufficient memory");
	}

	q->ptr = km->core_head, q->size = nu, km->core_head = q;
	p = (size_t*)(q + 1);
	*p = nu - 1; /* the size of the free block; -1 because the first unit is used for the core header */
	kfree(km, p + 1); /* initialize the new "core"; NB: the core header is not looped. */
	return km->loop_head;
}

void kfree(void *_km, void *ap) /* kfree() also adds a new core to the circular list */
{
	header_t *p, *q;
	kmem_t *km = (kmem_t*)_km;

	if (!ap) return;
	if (km == NULL) {
		free(ap);
		return;
	}
	p = (header_t*)((size_t*)ap - 1);
	p->size = *((size_t*)ap - 1);
	for (q = km->loop_head; !(p > q && p < q->ptr); q = q->ptr)
		if (q >= q->ptr && (p > q || p < q->ptr)) break;
	if (p + p->size == q->ptr) {
		p->size += q->ptr->size;
		p->ptr = q->ptr->ptr;
	} else if (p + p->size > q->ptr && q->ptr >= p) {
		panic("[kfree] The end of the allocated block enters a free block.");
	} else p->ptr = q->ptr;

	if (q + q->size == p) {
		q->size += p->size;
		q->ptr = p->ptr;
		km->loop_head = q;
	} else if (q + q->size > p && p >= q) {
		panic("[kfree] The end of a free block enters the allocated block.");
	} else km->loop_head = p, q->ptr = p;
}

void *kmalloc(void *_km, size_t n_bytes)
{
	kmem_t *km = (kmem_t*)_km;
	size_t n_units;
	header_t *p, *q;

	if (n_bytes == 0) return 0;
	if (km == NULL) return malloc(n_bytes);
	n_units = (n_bytes + sizeof(size_t) + sizeof(header_t) - 1) / sizeof(header_t);

	if (!(q = km->loop_head))
		q = km->loop_head = km->base.ptr = &km->base;
	for (p = q->ptr;; q = p, p = p->ptr) {
		if (p->size >= n_units) {
			if (p->size == n_units) q->ptr = p->ptr;
			else {
				p->size -= n_units;
				p += p->size;
				*(size_t*)p = n_units;
			}
			km->loop_head = q;
			return (size_t*)p + 1;
		}
		if (p == km->loop_head) {
			if ((p = morecore(km, n_units)) == 0) return 0;
		}
	}
}

void *kcalloc(void *_km, size_t count, size_t size)
{
	kmem_t *km = (kmem_t*)_km;
	void *p;
	if (size == 0 || count == 0) return 0;
	if (km == NULL) return calloc(count, size);
	p = kmalloc(km, count * size);
	memset(p, 0, count * size);
	return p;
}

void *krealloc(void *_km, void *ap, size_t n_bytes)
{
	kmem_t *km = (kmem_t*)_km;
	size_t cap, *p, *q;

	if (n_bytes == 0) {
		kfree(km, ap); return 0;
	}
	if (km == NULL) return realloc(ap, n_bytes);
	if (ap == NULL) return kmalloc(km, n_bytes);
	p = (size_t*)ap - 1;
	cap = (*p) * sizeof(header_t) - sizeof(size_t);
	if (cap >= n_bytes) return ap;
	q = (size_t*)kmalloc(km, n_bytes);
	memcpy(q, ap, cap);
	kfree(km, ap);
	return q;
}

void *krelocate(void *km, void *ap, size_t n_bytes)
{
	void *p;
	if (km == 0 || ap == 0) return ap;
	p = kmalloc(km, n_bytes);
	memcpy(p, ap, n_bytes);
	kfree(km, ap);
	return p;
}

void km_stat(const void *_km, km_stat_t *s)
{
	kmem_t *km = (kmem_t*)_km;
	header_t *p;
	memset(s, 0, sizeof(km_stat_t));
	if (km == NULL || km->loop_head == NULL) return;
	for (p = km->loop_head;; p = p->ptr) {
		s->available += p->size * sizeof(header_t);
		if (p->size != 0) ++s->n_blocks;
		if (p->ptr > p && p + p->size > p->ptr)
			panic("[km_stat] The end of a free block enters another free block.");
		if (p->ptr == km->loop_head) break;
	}
	for (p = km->core_head; p != NULL; p = p->ptr) {
		size_t size = p->size * sizeof(header_t);
		++s->n_cores;
		s->capacity += size;
		s->largest = s->largest > size? s->largest : size;
	}
}

void km_stat_print(const void *km)
{
	km_stat_t st;
	km_stat(km, &st);
	fprintf(stderr, "[km_stat] cap=%ld, avail=%ld, largest=%ld, n_core=%ld, n_block=%ld\n",
			st.capacity, st.available, st.largest, st.n_blocks, st.n_cores);
}
