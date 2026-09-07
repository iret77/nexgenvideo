#include "HangStackSampler.h"
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/arm/thread_status.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <ptrauth.h>

enum { NGV_MAX_THREADS = 512, NGV_MAX_FRAMES = 256 };
struct NGVThreadSample {
    uint64_t id;
    kern_return_t status;
    uint32_t count;
    uintptr_t frames[NGV_MAX_FRAMES];
};

static uintptr_t ngv_strip(uintptr_t address) {
    return (uintptr_t)ptrauth_strip((void *)address, ptrauth_key_return_address);
}

int ngv_capture_self(const char *path) {
    struct NGVThreadSample *samples = calloc(NGV_MAX_THREADS, sizeof(*samples));
    if (!samples) return 1;
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    kern_return_t result = task_threads(mach_task_self(), &threads, &count);
    if (result != KERN_SUCCESS) { free(samples); return 2; }
    thread_t self = mach_thread_self();
    uint32_t used = 0;
    for (uint32_t i = 0; i < count && used < NGV_MAX_THREADS; i++) {
        if (threads[i] == self) continue;
        struct NGVThreadSample *sample = &samples[used++];
        thread_identifier_info_data_t identity = {0};
        mach_msg_type_number_t info_count = THREAD_IDENTIFIER_INFO_COUNT;
        thread_info(threads[i], THREAD_IDENTIFIER_INFO, (thread_info_t)&identity, &info_count);
        sample->id = identity.thread_id;
        sample->status = thread_suspend(threads[i]);
        if (sample->status != KERN_SUCCESS) continue;
        // No allocation, logging, or library locks while another thread is suspended.
        arm_thread_state64_t state;
        mach_msg_type_number_t state_count = ARM_THREAD_STATE64_COUNT;
        sample->status = thread_get_state(threads[i], ARM_THREAD_STATE64,
                                         (thread_state_t)&state, &state_count);
        if (sample->status == KERN_SUCCESS) {
            sample->frames[sample->count++] = arm_thread_state64_get_pc(state);
            sample->frames[sample->count++] = arm_thread_state64_get_lr(state);
            uintptr_t fp = arm_thread_state64_get_fp(state);
            uintptr_t sp = arm_thread_state64_get_sp(state);
            while (sample->count < NGV_MAX_FRAMES && fp >= sp && fp - sp < 64 * 1024 * 1024
                   && fp % 16 == 0) {
                uintptr_t frame[2];
                mach_vm_size_t size = 0;
                kern_return_t read = mach_vm_read_overwrite(mach_task_self(), fp, sizeof(frame),
                                                           (mach_vm_address_t)frame, &size);
                if (read != KERN_SUCCESS || size != sizeof(frame)) break;
                sample->frames[sample->count++] = ngv_strip(frame[1]);
                if (frame[0] <= fp) break;
                fp = frame[0];
            }
        }
        kern_return_t resumed = thread_resume(threads[i]);
        if (resumed != KERN_SUCCESS) sample->status = resumed;
    }
    for (uint32_t i = 0; i < count; i++) mach_port_deallocate(mach_task_self(), threads[i]);
    mach_vm_deallocate(mach_task_self(), (mach_vm_address_t)threads, count * sizeof(thread_t));
    mach_port_deallocate(mach_task_self(), self);
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (fd < 0) { free(samples); return 3; }
    dprintf(fd, "NGV_SELF_STACKS_V1 threads=%u captured=%u\n", count, used);
    for (uint32_t i = 0; i < used; i++) {
        dprintf(fd, "thread %llu status=%d frames=%u\n", samples[i].id,
                samples[i].status, samples[i].count);
        for (uint32_t j = 0; j < samples[i].count; j++)
            dprintf(fd, "0x%llx\n", (uint64_t)samples[i].frames[j]);
    }
    free(samples);
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64) continue;
        const struct load_command *command = (const struct load_command *)(header + 1);
        for (uint32_t j = 0; j < header->ncmds; j++) {
            if (command->cmd == LC_UUID) {
                const struct uuid_command *uuid = (const struct uuid_command *)command;
                const char *name = _dyld_get_image_name(i);
                const char *basename = name ? strrchr(name, '/') : NULL;
                dprintf(fd, "image 0x%llx ", (uint64_t)header);
                for (int k = 0; k < 16; k++) dprintf(fd, "%02x", uuid->uuid[k]);
                dprintf(fd, " %s\n", basename ? basename + 1 : "unknown");
            }
            command = (const struct load_command *)((const char *)command + command->cmdsize);
        }
    }
    int failed = fsync(fd);
    close(fd);
    return failed == 0 ? 0 : 4;
}
