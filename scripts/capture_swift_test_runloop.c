#define _DARWIN_C_SOURCE 1
#include <CoreFoundation/CoreFoundation.h>
#include <crt_externs.h>
#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <mach-o/dyld-interposing.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <time.h>
#include <unistd.h>

enum { frame_limit = 24, other_stop_limit = 7, run_limit = 4, text_limit = 192 };
static int output_fd = -1;
static bool enabled;
static _Thread_local bool recording;
static _Thread_local unsigned run_depth;
static atomic_uint other_stops;
static atomic_uint main_stops;
static atomic_uint runs;
static atomic_uint sequences;
static atomic_uint stop_calls;
static atomic_uint write_failures;

struct record {
    char bytes[24 * 1024];
    size_t count;
    bool overflow;
};

static void append(struct record *row, const char *format, ...) {
    if (row->overflow) return;
    va_list arguments;
    va_start(arguments, format);
    int count = vsnprintf(row->bytes + row->count, sizeof(row->bytes) - row->count, format, arguments);
    va_end(arguments);
    if (count < 0 || (size_t)count >= sizeof(row->bytes) - row->count) {
        row->overflow = true;
        return;
    }
    row->count += (size_t)count;
}

static void string_limit(struct record *row, const char *value, size_t limit) {
    append(row, "\"");
    if (value) {
        for (size_t i = 0; value[i] && i < limit; ++i) {
            unsigned char byte = (unsigned char)value[i];
            if (byte == '"' || byte == '\\') append(row, "\\%c", byte);
            else if (byte < 0x20) append(row, "\\u%04x", byte);
            else append(row, "%c", byte);
        }
    }
    append(row, "\"");
}

static void string(struct record *row, const char *value) {
    string_limit(row, value, text_limit);
}

static void mode(struct record *row, CFRunLoopRef loop) {
    CFStringRef value = loop ? CFRunLoopCopyCurrentMode(loop) : NULL;
    char text[256] = "";
    if (value) {
        if (!CFStringGetCString(value, text, sizeof(text), kCFStringEncodingUTF8)) {
            memcpy(text, "<unavailable>", sizeof("<unavailable>"));
        }
        CFRelease(value);
    }
    if (value) string(row, text);
    else append(row, "null");
}

static void begin(struct record *row, const char *event) {
    struct timespec now = {0};
    uint64_t thread = 0;
    clock_gettime(CLOCK_MONOTONIC, &now);
    pthread_threadid_np(NULL, &thread);
    append(row, "{\"event\":");
    string(row, event);
    append(row, ",\"pid\":%d,\"parentPID\":%d,\"sequence\":%u,"
        "\"monotonicSeconds\":%lld,\"monotonicNanoseconds\":%ld,"
        "\"threadID\":%llu,\"mainThread\":%s",
        getpid(), getppid(), atomic_fetch_add(&sequences, 1),
        (long long)now.tv_sec, now.tv_nsec, (unsigned long long)thread,
        pthread_main_np() ? "true" : "false");
}

static void stack(struct record *row) {
    void *frames[frame_limit];
    int count = backtrace(frames, frame_limit);
    append(row, ",\"frameLimit\":%d,\"stack\":[", frame_limit);
    for (int i = 0; i < count; ++i) {
        Dl_info information = {0};
        dladdr(frames[i], &information);
        append(row, "%s{\"address\":\"%p\",\"image\":", i ? "," : "", frames[i]);
        const char *image = information.dli_fname ? strrchr(information.dli_fname, '/') : NULL;
        string(row, image ? image + 1 : information.dli_fname);
        append(row, ",\"imageBase\":\"%p\",\"symbol\":", information.dli_fbase);
        string(row, information.dli_sname);
        append(row, ",\"symbolAddress\":\"%p\"}", information.dli_saddr);
    }
    append(row, "]");
}

static void write_record(struct record *row, bool console) {
    append(row, "}\n");
    if (row->overflow) {
        atomic_fetch_add(&write_failures, 1);
        return;
    }
    if (output_fd >= 0) {
        ssize_t result = write(output_fd, row->bytes, row->count);
        if (result < 0 && errno == EINTR) result = write(output_fd, row->bytes, row->count);
        if (result != (ssize_t)row->count) {
            atomic_fetch_add(&write_failures, 1);
            static const char error[] = "[swift-test-runloop-probe] diagnostic-write-unavailable\n";
            (void)write(STDERR_FILENO, error, sizeof(error) - 1);
        }
    }
    if (console) {
        char prefix[] = "[swift-test-runloop-probe] ";
        struct iovec parts[] = {{prefix, sizeof(prefix) - 1}, {row->bytes, row->count}};
        (void)writev(STDERR_FILENO, parts, 2);
    }
}

static void counters(struct record *row) {
    unsigned other = atomic_load(&other_stops), main = atomic_load(&main_stops);
    unsigned run = atomic_load(&runs);
    append(row, ",\"stopCallsSeen\":%u,\"mainStopCallsSeen\":%u,\"otherStopSlotsRequested\":%u,"
        "\"otherStopCapReached\":%s,\"stopCallsOmittedByCap\":%u,\"firstMainStopSlotUnused\":%s,"
        "\"runCallsSeen\":%u,\"runPairsOmittedByCap\":%u,\"recordWriteFailures\":%u",
        atomic_load(&stop_calls), main, other, other >= other_stop_limit ? "true" : "false",
        other > other_stop_limit ? other - other_stop_limit : 0, main == 0 ? "true" : "false",
        run, run > run_limit ? run - run_limit : 0, atomic_load(&write_failures));
}

static void record_counters(void) {
    int saved_errno = errno;
    if (enabled && !recording) {
        recording = true;
        struct record row = {0};
        begin(&row, "probe-atexit-counters");
        counters(&row);
        write_record(&row, false);
        recording = false;
    }
    errno = saved_errno;
}

static const char *argument(const char *name, unsigned *matches) {
    const char *value = NULL;
    int count = *_NSGetArgc();
    char **arguments = *_NSGetArgv();
    for (int i = 1; i < count; ++i) {
        if (strcmp(arguments[i], name) == 0) {
            ++*matches;
            value = i + 1 < count ? arguments[i + 1] : NULL;
        }
    }
    return value;
}

static const char *cleanup_injection(char *library, int *error) {
    Dl_info information = {0};
    char inserted[PATH_MAX] = "";
    const char *value = getenv("DYLD_INSERT_LIBRARIES");
    if (!dladdr((const void *)&cleanup_injection, &information) || !information.dli_fname
            || !realpath(information.dli_fname, library)) {
        return "preserved-own-image-unavailable";
    }
    if (!value) return "already-absent";
    if (!realpath(value, inserted) || strcmp(inserted, library) != 0) {
        return "preserved-different-value";
    }
    if (!getenv("NGV_CF_RUNLOOP_PROBE_BUNDLE") || !getenv("NGV_CF_RUNLOOP_PROBE_BINARY")) {
        return "preserved-scope-unavailable";
    }
    if (unsetenv("DYLD_INSERT_LIBRARIES") != 0) {
        *error = errno;
        return "remove-unavailable";
    }
    return "removed-own-library";
}

__attribute__((constructor))
static void initialize(void) {
    int saved_errno = errno;
    char executable[PATH_MAX] = "";
    uint32_t capacity = sizeof(executable);
    if (_NSGetExecutablePath(executable, &capacity) != 0) goto done;
    const char *name = strrchr(executable, '/');
    const char *leaf = name ? name + 1 : executable;
    bool helper = strcmp(leaf, "swiftpm-testing-helper") == 0;
    if (!helper && strcmp(leaf, "xctest") != 0) goto done;
    if (!getenv("NGV_SWIFT_TEST_PROCESS_EVIDENCE")) goto done;
    recording = true;
    char library_path[PATH_MAX] = "";
    int cleanup_error = 0;
    const char *cleanup = cleanup_injection(library_path, &cleanup_error);
    const char *directory = getenv("NGV_SWIFT_TEST_PROCESS_EVIDENCE");
    if (!directory) {
        recording = false;
        goto done;
    }
    unsigned bundle_matches = 0, library_matches = 0;
    const char *bundle = argument("--test-bundle-path", &bundle_matches);
    const char *library = argument("--testing-library", &library_matches);
    const char *expected_bundle = getenv("NGV_CF_RUNLOOP_PROBE_BUNDLE");
    const char *expected_binary = getenv("NGV_CF_RUNLOOP_PROBE_BINARY");
    char resolved[PATH_MAX] = "";
    bool matched = helper && bundle_matches == 1 && library_matches == 1 && bundle && library
        && strcmp(library, "swift-testing") == 0 && expected_bundle && expected_binary
        && realpath(bundle, resolved)
        && (strcmp(resolved, expected_bundle) == 0 || strcmp(resolved, expected_binary) == 0);
    char path[PATH_MAX];
    int length = snprintf(path, sizeof(path), "%s/runloop-probe-%d.jsonl", directory, getpid());
    if (length >= 0 && (size_t)length < sizeof(path)) {
        output_fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    }
    enabled = matched && output_fd >= 0;
    int exit_registration = enabled ? atexit(record_counters) : -1;
    struct record row = {0};
    begin(&row, helper ? "probe-init" : "probe-host-init");
    append(&row, ",\"executable\":");
    string_limit(&row, executable, PATH_MAX);
    append(&row, ",\"loadedLibrary\":");
    string_limit(&row, library_path, PATH_MAX);
    append(&row, ",\"injectionCleanup\":");
    string(&row, cleanup);
    append(&row, ",\"injectionCleanupErrno\":%d", cleanup_error);
    append(&row, ",\"testBundle\":");
    string_limit(&row, bundle, PATH_MAX);
    append(&row, ",\"testingLibrary\":");
    string(&row, library);
    append(&row, ",\"bundleFlagCount\":%u,\"libraryFlagCount\":%u,"
        "\"guardMatched\":%s,\"outputAvailable\":%s,\"stopLimit\":%d,\"runLimit\":%d",
        bundle_matches, library_matches, matched ? "true" : "false",
        output_fd >= 0 ? "true" : "false", other_stop_limit + 1, run_limit);
    append(&row, ",\"atexitRegistrationResult\":%d,\"symbolTextLimit\":%d,\"recordByteLimit\":%zu",
        exit_registration, text_limit, sizeof(row.bytes));
    write_record(&row, helper);
    recording = false;
done:
    errno = saved_errno;
}

static void record_loop(const char *event, CFRunLoopRef loop, unsigned activation) {
    struct record row = {0};
    begin(&row, event);
    append(&row, ",\"runLoop\":\"%p\",\"targetIsMainLoop\":%s,\"runDepth\":%u,"
        "\"activation\":%u,\"targetMode\":", loop,
        loop == CFRunLoopGetMain() ? "true" : "false", run_depth, activation);
    mode(&row, loop);
    CFRunLoopRef caller = CFRunLoopGetCurrent();
    append(&row, ",\"callerRunLoop\":\"%p\",\"callerEqualsTarget\":%s,\"callerMode\":",
        caller, caller == loop ? "true" : "false");
    mode(&row, caller);
    counters(&row);
    stack(&row);
    write_record(&row, false);
}

static void observed_stop(CFRunLoopRef loop) {
    int saved_errno = errno;
    if (enabled && !recording) {
        recording = true;
        atomic_fetch_add(&stop_calls, 1);
        bool main = loop == CFRunLoopGetMain();
        bool selected = main && atomic_fetch_add(&main_stops, 1) == 0;
        if (!selected) selected = atomic_fetch_add(&other_stops, 1) < other_stop_limit;
        if (selected) record_loop("CFRunLoopStop", loop, 0);
        recording = false;
    }
    errno = saved_errno;
    CFRunLoopStop(loop);
}

static void observed_run(void) {
    int saved_errno = errno;
    bool selected = false;
    unsigned activation = 0;
    CFRunLoopRef loop = NULL;
    if (enabled && !recording) {
        recording = true;
        activation = atomic_fetch_add(&runs, 1);
        selected = activation < run_limit;
        ++run_depth;
        if (selected) {
            loop = CFRunLoopGetCurrent();
            record_loop("CFRunLoopRun-entry", loop, activation);
        }
        recording = false;
    }
    errno = saved_errno;
    CFRunLoopRun();
    int result_errno = errno;
    if (enabled && !recording) {
        recording = true;
        if (selected) record_loop("CFRunLoopRun-return", loop, activation);
        --run_depth;
        recording = false;
    }
    errno = result_errno;
}

DYLD_INTERPOSE(observed_stop, CFRunLoopStop)
DYLD_INTERPOSE(observed_run, CFRunLoopRun)
