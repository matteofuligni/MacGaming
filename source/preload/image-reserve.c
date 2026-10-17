// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 MacGaming contributors. See COPYRIGHT and LICENSE.
//
// Keeps the address range of a fixed-base Windows executable free when Hadron's Wine loader starts.
//
// Wine creates every process by executing its loader with WINEPRELOADRESERVE=<start>-<end>, the
// range the new process's main executable wants. On Linux a preloader reserves that range before
// libc runs. Hadron's macOS loader only reserves the low 4 GiB, and macOS malloc places a 16 KiB
// metadata region at a random address between about 0x11c600000 and 0x15c000000 before any
// program code runs. A 64-bit executable without relocations at the usual 0x140000000 base then
// fails with STATUS_CONFLICTING_ADDRESSES (c0000018) whenever that region falls inside its image:
// almost half of the starts for Hogwarts Legacy's 444 MiB image.
//
// Loaded through DYLD_INSERT_LIBRARIES, this library runs before the loader's main(). When the
// requested range above 4 GiB is occupied it executes the loader again with the same arguments
// and environment, which draws a new malloc placement. Processes whose range is already free,
// and every program other than Wine's loader, are left unchanged.
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

#define ATTEMPT_VARIABLE "MACGAMING_IMAGE_RESERVE_ATTEMPT"
/* With a 0.5 chance of conflict per start, 32 restarts leave about one failure in four billion. */
#define MAX_ATTEMPTS 32
#define LOW_RESERVE_END 0x100000000ULL

/* Start of the first mapping that overlaps [start, end), or 0 when the range is free. */
static mach_vm_address_t first_mapping(mach_vm_address_t start, mach_vm_address_t end)
{
    mach_vm_address_t address = start;
    mach_vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;

    /* Returns the first region that ends after start, or fails when there is none. */
    if (mach_vm_region(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
                       (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS || address >= end)
        return 0;
    return address;
}

__attribute__((constructor))
static void keep_image_range_free(int argc, char **argv)
{
    const char *range = getenv("WINEPRELOADRESERVE");
    const char *attempt_text = getenv(ATTEMPT_VARIABLE);
    unsigned long long start, end, occupant;
    int attempt = attempt_text ? atoi(attempt_text) : 0;
    char path[PATH_MAX], number[16];
    uint32_t path_size = sizeof(path);

    (void)argc;
    /* Ranges below 4 GiB lie in the loader's own reservation; builtin images pass an empty range. */
    if (!range || sscanf(range, "%llx-%llx", &start, &end) != 2 || end <= start || start < LOW_RESERVE_END)
        return;
    /* Only Wine's loader exports the preload list; wineserver and other programs inherit the variable. */
    if (!dlsym(RTLD_MAIN_ONLY, "wine_main_preload_info"))
        return;

    if (!(occupant = first_mapping(start, end)))
    {
        if (attempt > 0)
        {
            fprintf(stderr, "macgaming: image range %s free after %d loader restart(s)\n", range, attempt);
            unsetenv(ATTEMPT_VARIABLE);
        }
        return;
    }
    /* Until main() runs, the page zero reaches from 0 to the loader's image, past 4 GiB by its random
     * slide. A range just above 4 GiB overlaps it in every start, so a restart cannot help. */
    if (occupant < LOW_RESERVE_END)
    {
        fprintf(stderr, "macgaming: image range %s overlaps the loader's page zero\n", range);
        unsetenv(ATTEMPT_VARIABLE);
        return;
    }
    if (attempt >= MAX_ATTEMPTS || _NSGetExecutablePath(path, &path_size) != 0)
    {
        fprintf(stderr, "macgaming: image range %s still occupied after %d loader restart(s)\n", range, attempt);
        unsetenv(ATTEMPT_VARIABLE);
        return;
    }
    snprintf(number, sizeof(number), "%d", attempt + 1);
    setenv(ATTEMPT_VARIABLE, number, 1);
    execv(path, argv);
    /* The loader could not be executed again: continue, Wine reports the conflict as before. */
    unsetenv(ATTEMPT_VARIABLE);
}
