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
#include <sys/resource.h>
#include <stdint.h>
#include <string.h>
#include <ptrauth.h>

enum { NGV_MAX_THREADS = 512, NGV_MAX_FRAMES = 256 };
struct NGVImage { const struct mach_header *address; uint8_t uuid[16]; };
static struct NGVImage image_map[2048];
static pthread_mutex_t image_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t initialize_once = PTHREAD_ONCE_INIT;
static uint64_t main_thread_id = 0;

static void ngv_add_image(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    if (header->magic != MH_MAGIC_64) return;
    const struct load_command *command = (const struct load_command *)((const struct mach_header_64 *)header + 1);
    for (uint32_t j = 0; j < header->ncmds; j++) {
        if (command->cmd == LC_UUID) {
            const struct uuid_command *uuid = (const struct uuid_command *)command;
            pthread_mutex_lock(&image_lock);
            for (size_t i = 0; i < 2048; i++) {
                if (!image_map[i].address) {
                    image_map[i].address = header;
                    memcpy(image_map[i].uuid, uuid->uuid, 16);
                    break;
                }
            }
            pthread_mutex_unlock(&image_lock);
            return;
        }
        command = (const struct load_command *)((const char *)command + command->cmdsize);
    }
}

static void ngv_remove_image(const struct mach_header *header, intptr_t slide) {
    (void)slide;
    pthread_mutex_lock(&image_lock);
    for (size_t i = 0; i < 2048; i++) if (image_map[i].address == header) image_map[i].address = NULL;
    pthread_mutex_unlock(&image_lock);
}

static void ngv_initialize(void) {
    _dyld_register_func_for_add_image(ngv_add_image);
    _dyld_register_func_for_remove_image(ngv_remove_image);
}

void ngv_sampler_initialize(void) {
    if (pthread_main_np()) pthread_threadid_np(NULL, &main_thread_id);
    pthread_once(&initialize_once, ngv_initialize);
}
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
    ngv_sampler_initialize();
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
    struct rusage usage = {0};
    getrusage(RUSAGE_SELF, &usage);
    dprintf(fd, "main-thread %llu user-cpu %ld.%06d system-cpu %ld.%06d max-rss %ld\n",
            main_thread_id, usage.ru_utime.tv_sec, usage.ru_utime.tv_usec,
            usage.ru_stime.tv_sec, usage.ru_stime.tv_usec, usage.ru_maxrss);
    for (uint32_t i = 0; i < used; i++) {
        dprintf(fd, "thread %llu status=%d frames=%u\n", samples[i].id,
                samples[i].status, samples[i].count);
        for (uint32_t j = 0; j < samples[i].count; j++)
            dprintf(fd, "0x%llx\n", (uint64_t)samples[i].frames[j]);
    }
    free(samples);
    struct NGVImage images[2048];
    pthread_mutex_lock(&image_lock);
    memcpy(images, image_map, sizeof(images));
    pthread_mutex_unlock(&image_lock);
    for (size_t i = 0; i < 2048; i++) {
        if (!images[i].address) continue;
        dprintf(fd, "image 0x%llx ", (uint64_t)images[i].address);
        for (int k = 0; k < 16; k++) dprintf(fd, "%02x", images[i].uuid[k]);
        dprintf(fd, "\n");
    }
    int failed = fsync(fd);
    close(fd);
    return failed == 0 ? 0 : 4;
}
