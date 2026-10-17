/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
 */
/* CPUID consistency check for MacGaming. Twice as many threads as processors, half of them at idle
 * priority, repeat the same CPUID leaves (and XGETBV/RDTSCP when available) while yielding, so the
 * scheduler moves them between performance and efficiency cores. A real processor gives every core
 * the same answers apart from the fields that name the core (APIC IDs). The probe prints every
 * distinct answer per leaf and whether answers differ outside those fields.
 * Exit code: 0 consistent, 1 answers differ outside per-core fields, 2 setup failure.
 * Build: source/build.sh probe. Usage: cpuid-consistency.exe [iterations-per-thread] */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cpuid.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAX_VARIANTS 64  /* at least one per core: leaf 1 differs in its APIC ID on every core */
#define MAX_THREADS 64
#define MAX_IDS 64

struct leaf
{
    unsigned int leaf, subleaf;
    unsigned int core_mask[4];  /* bits that legitimately name the core: ignored when comparing */
    const char *note;
};

static const struct leaf leaves[] =
{
    { 0x00000000, 0, { 0, 0, 0, 0 }, "vendor, max standard leaf" },
    { 0x00000001, 0, { 0, 0xff000000, 0, 0 }, "features; EBX[31:24] is the core's APIC ID" },
    { 0x00000006, 0, { 0, 0, 0, 0 }, "power management" },
    { 0x00000007, 0, { 0, 0, 0, 0 }, "extended features" },
    { 0x00000007, 1, { 0, 0, 0, 0 }, "extended features, subleaf 1" },
    { 0x0000000b, 0, { 0, 0, 0, 0xffffffff }, "topology; EDX is the core's x2APIC ID" },
    { 0x0000000b, 1, { 0, 0, 0, 0xffffffff }, "topology level 1" },
    { 0x0000000d, 0, { 0, 0, 0, 0 }, "XSAVE state" },
    { 0x0000000d, 1, { 0, 0, 0, 0 }, "XSAVE extensions" },
    { 0x40000000, 0, { 0, 0, 0, 0 }, "hypervisor/emulator identification" },
    { 0x80000000, 0, { 0, 0, 0, 0 }, "max extended leaf" },
    { 0x80000001, 0, { 0, 0, 0, 0 }, "extended features" },
    { 0x80000002, 0, { 0, 0, 0, 0 }, "brand string 1/3" },
    { 0x80000003, 0, { 0, 0, 0, 0 }, "brand string 2/3" },
    { 0x80000004, 0, { 0, 0, 0, 0 }, "brand string 3/3" },
    { 0x80000007, 0, { 0, 0, 0, 0 }, "invariant TSC" },
    { 0x80000008, 0, { 0, 0, 0, 0 }, "address sizes" },
};
#define LEAF_COUNT (sizeof(leaves) / sizeof(leaves[0]))
#define XGETBV_SLOT LEAF_COUNT  /* XGETBV(0) stored like a leaf: EAX/EDX in the first two registers */
#define SLOTS (LEAF_COUNT + 1)

struct variants
{
    unsigned int regs[MAX_VARIANTS][4];
    unsigned long long hits[MAX_VARIANTS];
    unsigned int threads[MAX_VARIANTS];
    int count;
    unsigned long long overflow;
};

struct ids
{
    unsigned int value[MAX_IDS];
    int count;
};

struct worker
{
    int index, priority, iterations, has_xgetbv, has_rdtscp;
    struct variants seen[SLOTS];
    struct ids apic, tsc_aux;
};

static void record(struct variants *v, const unsigned int regs[4], unsigned long long hits)
{
    int i;

    for (i = 0; i < v->count; i++)
        if (!memcmp(v->regs[i], regs, sizeof(v->regs[i]))) break;
    if (i == v->count)
    {
        if (v->count == MAX_VARIANTS) { v->overflow += hits; return; }
        memcpy(v->regs[v->count++], regs, sizeof(v->regs[i]));
    }
    v->hits[i] += hits;
}

static void add_id(struct ids *ids, unsigned int value)
{
    int i;

    for (i = 0; i < ids->count; i++) if (ids->value[i] == value) return;
    if (ids->count < MAX_IDS) ids->value[ids->count++] = value;
}

static DWORD WINAPI run_worker(void *arg)
{
    struct worker *w = arg;
    unsigned int regs[4], aux;
    unsigned long long xcr0;
    int i, l;

    SetThreadPriority(GetCurrentThread(), w->priority);
    for (i = 0; i < w->iterations; i++)
    {
        for (l = 0; l < (int)LEAF_COUNT; l++)
        {
            __cpuid_count(leaves[l].leaf, leaves[l].subleaf, regs[0], regs[1], regs[2], regs[3]);
            record(&w->seen[l], regs, 1);
            if (leaves[l].leaf == 1) add_id(&w->apic, regs[1] >> 24);
        }
        if (w->has_xgetbv)
        {
            unsigned int lo, hi;
            __asm__ volatile("xgetbv" : "=a"(lo), "=d"(hi) : "c"(0));
            xcr0 = ((unsigned long long)hi << 32) | lo;
            regs[0] = (unsigned int)xcr0; regs[1] = (unsigned int)(xcr0 >> 32); regs[2] = regs[3] = 0;
            record(&w->seen[XGETBV_SLOT], regs, 1);
        }
        if (w->has_rdtscp)
        {
            unsigned int lo, hi;
            __asm__ volatile("rdtscp" : "=a"(lo), "=d"(hi), "=c"(aux));
            add_id(&w->tsc_aux, aux);
        }
        /* Give the scheduler chances to move this thread to another core. */
        if (!(i % 64)) SwitchToThread();
        if (!(i % 1024)) Sleep(1);
    }
    return 0;
}

static void print_regs(const unsigned int regs[4])
{
    printf("eax=%08x ebx=%08x ecx=%08x edx=%08x", regs[0], regs[1], regs[2], regs[3]);
}

int main(int argc, char **argv)
{
    static struct worker workers[MAX_THREADS];
    static struct variants merged[SLOTS];
    HANDLE threads[MAX_THREADS];
    SYSTEM_INFO info;
    unsigned int regs[4], max_standard, max_extended, brand[12], vendor[4] = { 0 }, hypervisor[4] = { 0 };
    int iterations = argc > 1 ? atoi(argv[1]) : 20000, count, i, l, v, inconsistent = 0, has_xgetbv, has_rdtscp;
    struct ids apic = { { 0 }, 0 }, tsc_aux = { { 0 }, 0 };
    int most_apic = 0, most_aux = 0;

    if (iterations <= 0) iterations = 20000;
    GetSystemInfo(&info);
    count = (int)info.dwNumberOfProcessors * 2;
    if (count > MAX_THREADS) count = MAX_THREADS;
    if (count < 2) count = 2;

    __cpuid(0, max_standard, vendor[0], vendor[2], vendor[1]);
    __cpuid(0x80000000, max_extended, regs[1], regs[2], regs[3]);
    __cpuid(1, regs[0], regs[1], regs[2], regs[3]);
    has_xgetbv = (regs[2] >> 27) & 1;  /* OSXSAVE */
    __cpuid(0x40000000, regs[0], hypervisor[0], hypervisor[1], hypervisor[2]);
    for (i = 0; i < 3; i++) __cpuid(0x80000002 + i, brand[i * 4], brand[i * 4 + 1], brand[i * 4 + 2], brand[i * 4 + 3]);
    __cpuid(0x80000001, regs[0], regs[1], regs[2], regs[3]);
    has_rdtscp = max_extended >= 0x80000001 && ((regs[3] >> 27) & 1);

    printf("processors=%lu threads=%d iterations-per-thread=%d\n", (unsigned long)info.dwNumberOfProcessors, count, iterations);
    printf("vendor=\"%.12s\" brand=\"%.48s\" hypervisor-leaf=\"%.12s\"\n", (char *)vendor, (char *)brand, (char *)hypervisor);
    printf("max-standard-leaf=%#x max-extended-leaf=%#x xgetbv=%s rdtscp=%s\n", max_standard, max_extended,
           has_xgetbv ? "yes" : "no", has_rdtscp ? "yes" : "no");
    fflush(stdout);

    for (i = 0; i < count; i++)
    {
        workers[i].index = i;
        workers[i].priority = (i % 2) ? THREAD_PRIORITY_IDLE : THREAD_PRIORITY_NORMAL;
        workers[i].iterations = iterations;
        workers[i].has_xgetbv = has_xgetbv;
        workers[i].has_rdtscp = has_rdtscp;
        if (!(threads[i] = CreateThread(NULL, 0, run_worker, &workers[i], 0, NULL)))
        {
            printf("CreateThread failed: %lu\n", GetLastError());
            return 2;
        }
    }
    WaitForMultipleObjects(count, threads, TRUE, INFINITE);

    for (i = 0; i < count; i++)
    {
        for (l = 0; l < (int)SLOTS; l++)
        {
            struct variants *seen = &workers[i].seen[l];
            for (v = 0; v < seen->count; v++)
            {
                int m;
                record(&merged[l], seen->regs[v], seen->hits[v]);
                for (m = 0; m < merged[l].count; m++)
                    if (!memcmp(merged[l].regs[m], seen->regs[v], sizeof(merged[l].regs[m]))) { merged[l].threads[m]++; break; }
            }
            merged[l].overflow += seen->overflow;
        }
        for (v = 0; v < workers[i].apic.count; v++) add_id(&apic, workers[i].apic.value[v]);
        for (v = 0; v < workers[i].tsc_aux.count; v++) add_id(&tsc_aux, workers[i].tsc_aux.value[v]);
        if (workers[i].apic.count > most_apic) most_apic = workers[i].apic.count;
        if (workers[i].tsc_aux.count > most_aux) most_aux = workers[i].tsc_aux.count;
        CloseHandle(threads[i]);
    }

    for (l = 0; l < (int)SLOTS; l++)
    {
        const unsigned int *mask = l < (int)LEAF_COUNT ? leaves[l].core_mask : (const unsigned int[4]){ 0, 0, 0, 0 };
        int masked_differs = 0, r;

        if (l == XGETBV_SLOT && !has_xgetbv) continue;
        for (v = 1; v < merged[l].count; v++)
            for (r = 0; r < 4; r++)
                if ((merged[l].regs[v][r] & ~mask[r]) != (merged[l].regs[0][r] & ~mask[r])) masked_differs = 1;
        if (merged[l].overflow) masked_differs = 1;
        if (masked_differs) inconsistent++;
        if (l < (int)LEAF_COUNT)
            printf("leaf %08x.%u (%s)%s: ", leaves[l].leaf, leaves[l].subleaf, leaves[l].note,
                   (leaves[l].leaf < 0x40000000 ? leaves[l].leaf > max_standard
                    : leaves[l].leaf >= 0x80000000 && leaves[l].leaf > max_extended) ? " [beyond max leaf]" : "");
        else
            printf("xgetbv(0): ");
        printf("%d answer(s)%s%s\n", merged[l].count, merged[l].overflow ? ", more not stored" : "",
               masked_differs ? ", DIFFERENT outside per-core fields" : merged[l].count > 1 ? ", same outside per-core fields" : "");
        for (v = 0; v < merged[l].count; v++)
        {
            printf("    ");
            print_regs(merged[l].regs[v]);
            printf("  hits=%llu threads=%u\n", merged[l].hits[v], merged[l].threads[v]);
        }
    }
    printf("apic-ids=%d distinct, at most %d per thread", apic.count, most_apic);
    if (has_rdtscp) printf("; rdtscp-aux=%d distinct, at most %d per thread", tsc_aux.count, most_aux);
    printf("\nresult=%s\n", inconsistent ? "INCONSISTENT" : "consistent");
    fflush(stdout);
    return inconsistent ? 1 : 0;
}
