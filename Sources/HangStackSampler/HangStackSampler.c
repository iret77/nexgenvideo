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
#include <stdatomic.h>
#include <errno.h>

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
static struct NGVThreadSample sample_buffer[NGV_MAX_THREADS];
static atomic_flag capture_active = ATOMIC_FLAG_INIT;

struct NGVOutput { int fd; int failed; size_t count; char bytes[16384]; };

static void ngv_flush(struct NGVOutput *output) {
    size_t offset = 0;
    while (offset < output->count && !output->failed) {
        ssize_t written = write(output->fd, output->bytes + offset, output->count - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) { output->failed = 1; break; }
        offset += (size_t)written;
    }
    output->count = 0;
}

static void ngv_text(struct NGVOutput *output, const char *text) {
    while (*text) {
        if (output->count == sizeof(output->bytes)) ngv_flush(output);
        output->bytes[output->count++] = *text++;
    }
}

static void ngv_number(struct NGVOutput *output, uint64_t number, unsigned base) {
    char reverse[65];
    size_t count = 0;
    do { reverse[count++] = "0123456789abcdef"[number % base]; number /= base; } while (number);
    while (count) {
        char character[2] = { reverse[--count], 0 };
        ngv_text(output, character);
    }
}

static uintptr_t ngv_strip(uintptr_t address) {
    return (uintptr_t)ptrauth_strip((void *)address, ptrauth_key_return_address);
}

int ngv_capture_self(const char *path) {
    ngv_sampler_initialize();
    if (atomic_flag_test_and_set(&capture_active)) return 1;
    struct NGVThreadSample *samples = sample_buffer;
    memset(samples, 0, sizeof(sample_buffer));
    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    kern_return_t result = task_threads(mach_task_self(), &threads, &count);
    if (result != KERN_SUCCESS) { atomic_flag_clear(&capture_active); return 2; }
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
    if (fd < 0) { atomic_flag_clear(&capture_active); return 3; }
    struct NGVOutput output = { .fd = fd };
    ngv_text(&output, "NGV_SELF_STACKS_V1 threads="); ngv_number(&output, count, 10);
    ngv_text(&output, " captured="); ngv_number(&output, used, 10); ngv_text(&output, "\n");
    struct rusage usage = {0};
    getrusage(RUSAGE_SELF, &usage);
    ngv_text(&output, "main-thread "); ngv_number(&output, main_thread_id, 10);
    ngv_text(&output, " user-cpu-us "); ngv_number(&output, usage.ru_utime.tv_sec * 1000000ULL + usage.ru_utime.tv_usec, 10);
    ngv_text(&output, " system-cpu-us "); ngv_number(&output, usage.ru_stime.tv_sec * 1000000ULL + usage.ru_stime.tv_usec, 10);
    ngv_text(&output, " max-rss "); ngv_number(&output, usage.ru_maxrss, 10); ngv_text(&output, "\n");
    int main_captured = main_thread_id == 0;
    for (uint32_t i = 0; i < used; i++) {
        if (samples[i].id == main_thread_id && samples[i].status == KERN_SUCCESS && samples[i].count > 0) main_captured = 1;
        ngv_text(&output, "thread "); ngv_number(&output, samples[i].id, 10);
        ngv_text(&output, " status="); ngv_number(&output, samples[i].status, 10);
        ngv_text(&output, " frames="); ngv_number(&output, samples[i].count, 10); ngv_text(&output, "\n");
        for (uint32_t j = 0; j < samples[i].count; j++) {
            ngv_text(&output, "0x"); ngv_number(&output, samples[i].frames[j], 16); ngv_text(&output, "\n");
        }
    }
    struct NGVImage images[2048];
    pthread_mutex_lock(&image_lock);
    memcpy(images, image_map, sizeof(images));
    pthread_mutex_unlock(&image_lock);
    for (size_t i = 0; i < 2048; i++) {
        if (!images[i].address) continue;
        ngv_text(&output, "image 0x"); ngv_number(&output, (uint64_t)images[i].address, 16); ngv_text(&output, " ");
        for (int k = 0; k < 16; k++) {
            char hex[3] = { "0123456789abcdef"[images[i].uuid[k] >> 4], "0123456789abcdef"[images[i].uuid[k] & 15], 0 };
            ngv_text(&output, hex);
        }
        ngv_text(&output, "\n");
    }
    ngv_flush(&output);
    int failed = fsync(fd);
    close(fd);
    atomic_flag_clear(&capture_active);
    return failed != 0 || output.failed ? 4 : main_captured ? 0 : 5;
}
