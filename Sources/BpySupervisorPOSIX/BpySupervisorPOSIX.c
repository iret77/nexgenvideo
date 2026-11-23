#include "BpySupervisorPOSIX.h"
#include <sys/resource.h>

uint64_t ngv_bpy_rlim_infinity(void) {
    return RLIM_INFINITY;
}
