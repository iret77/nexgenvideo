#import <Foundation/Foundation.h>
#include "BpySupervisorPOSIX.h"
#include <errno.h>

int ngv_bpy_file_handle_descriptor(void *handle, int *descriptor) {
    if (!handle || !descriptor) return EINVAL;
    *descriptor = -1;
    @try {
        int value = [(__bridge NSFileHandle *)handle fileDescriptor];
        if (value < 0) return EBADF;
        *descriptor = value;
        return 0;
    } @catch (NSException *exception) {
        return [exception.name isEqualToString:NSFileHandleOperationException] ? EBADF : EIO;
    }
}
