#include "BpySupervisorPOSIX.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <unistd.h>
#include <libproc.h>
#include <stdint.h>

enum { parent_lifeline = 198 };

static pthread_once_t spawn_once = PTHREAD_ONCE_INIT;
static pthread_mutex_t spawn_mutex;
static int spawn_mutex_error;

static void initialize_spawn_mutex(void) {
    pthread_mutexattr_t attributes;
    spawn_mutex_error = pthread_mutexattr_init(&attributes);
    if (spawn_mutex_error) return;
    spawn_mutex_error = pthread_mutexattr_settype(&attributes, PTHREAD_MUTEX_RECURSIVE);
    if (!spawn_mutex_error) spawn_mutex_error = pthread_mutex_init(&spawn_mutex, &attributes);
    pthread_mutexattr_destroy(&attributes);
}

int ngv_bpy_spawn_lock(void) {
    int error = pthread_once(&spawn_once, initialize_spawn_mutex);
    if (error || spawn_mutex_error) return error ? error : spawn_mutex_error;
    return pthread_mutex_lock(&spawn_mutex);
}

int ngv_bpy_spawn_unlock(void) { return pthread_mutex_unlock(&spawn_mutex); }

int ngv_bpy_self_path(char *buffer, size_t size) {
    if (!buffer || size == 0 || size > PROC_PIDPATHINFO_MAXSIZE) return EINVAL;
    int count = proc_pidpath(getpid(), buffer, (uint32_t)size);
    return count > 0 ? 0 : (errno ? errno : EIO);
}

struct ngv_bpy_child {
    pthread_mutex_t lock;
    pid_t pid;
    int lifeline;
    int reaped;
    int exit_status;
    int termination_signal;
};

static int inherit_descriptor(posix_spawn_file_actions_t *actions, int source, int target) {
    if (source == -1) return posix_spawn_file_actions_addopen(actions, target, "/dev/null", O_RDWR, 0);
    if (source < -1) return EBADF;
    if (source == target) return posix_spawn_file_actions_addinherit_np(actions, source);
    return posix_spawn_file_actions_adddup2(actions, source, target);
}

int ngv_bpy_child_spawn(const char *path, char *const argv[], char *const envp[],
    const char *directory, int input, int output, int errors, ngv_bpy_child **result) {
    return ngv_bpy_child_spawn_descriptors(path, argv, envp, directory, -1,
                                         input, output, errors, NULL, 0, result);
}

static int duplicate_source(int source, const ngv_bpy_fd_map *mappings, size_t count) {
    int minimum = STDERR_FILENO + 1;
    while (1) {
        int duplicate = fcntl(source, F_DUPFD_CLOEXEC, minimum);
        if (duplicate < 0) return -1;
        int reserved = duplicate == parent_lifeline;
        for (size_t index = 0; index < count; ++index) reserved |= duplicate == mappings[index].target;
        if (!reserved) return duplicate;
        minimum = duplicate + 1;
        close(duplicate);
    }
}

int ngv_bpy_child_spawn_descriptors(const char *path, char *const argv[], char *const envp[],
    const char *directory, int directory_fd, int input, int output, int errors,
    const ngv_bpy_fd_map *mappings, size_t mapping_count, ngv_bpy_child **result) {
    if (!path || !argv || !envp || !directory || !result || mapping_count > 16 ||
        (mapping_count && !mappings) || directory_fd < -1) return EINVAL;
    *result = NULL;
    for (size_t index = 0; index < mapping_count; ++index) {
        if (mappings[index].source < 0 || mappings[index].target <= STDERR_FILENO ||
            mappings[index].target == parent_lifeline) return EINVAL;
        for (size_t previous = 0; previous < index; ++previous)
            if (mappings[previous].target == mappings[index].target) return EINVAL;
    }
    int error = ngv_bpy_spawn_lock();
    if (error) return error;
    struct sigaction child_signal;
    if (sigaction(SIGCHLD, NULL, &child_signal) != 0) { error = errno; goto fail_lock; }
    if (child_signal.sa_handler == SIG_IGN || (child_signal.sa_flags & SA_NOCLDWAIT)) {
        error = EINVAL; goto fail_lock;
    }
    struct rlimit descriptors;
    if (getrlimit(RLIMIT_NOFILE, &descriptors) != 0) { error = errno; goto fail_lock; }
    if (descriptors.rlim_cur <= parent_lifeline) { error = EMFILE; goto fail_lock; }
    for (size_t index = 0; index < mapping_count; ++index)
        if ((rlim_t)mappings[index].target >= descriptors.rlim_cur) { error = EMFILE; goto fail_lock; }
    ngv_bpy_child *child = calloc(1, sizeof(*child));
    if (!child) { error = ENOMEM; goto fail_lock; }
    error = pthread_mutex_init(&child->lock, NULL);
    if (error) { free(child); goto fail_lock; }
    int ends[2];
    if (pipe(ends) != 0) { error = errno; goto fail_mutex; }
    if (ends[0] <= STDERR_FILENO) {
        int moved = fcntl(ends[0], F_DUPFD_CLOEXEC, STDERR_FILENO + 1);
        if (moved < 0) { error = errno; goto fail_pipe; }
        close(ends[0]);
        ends[0] = moved;
    }
    if (fcntl(ends[0], F_SETFD, FD_CLOEXEC) != 0 || fcntl(ends[1], F_SETFD, FD_CLOEXEC) != 0) {
        error = errno; goto fail_pipe;
    }
    posix_spawn_file_actions_t actions;
    error = posix_spawn_file_actions_init(&actions);
    if (error) goto fail_pipe;
    posix_spawnattr_t attributes;
    error = posix_spawnattr_init(&attributes);
    if (error) goto fail_actions;
    sigset_t empty, defaults;
    sigemptyset(&empty);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGTERM);
    sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGPIPE);
    int sources[21];
    size_t source_count = 0;
    int original_sources[5] = { input, output, errors, ends[0], directory_fd };
    for (size_t index = 0; index < 5 + mapping_count; ++index) {
        int source = index < 5 ? original_sources[index] : mappings[index - 5].source;
        int duplicate = source < 0 ? source : duplicate_source(source, mappings, mapping_count);
        if (source >= 0 && duplicate < 0) { error = errno; goto fail_sources; }
        sources[source_count++] = duplicate;
    }
    if ((error = posix_spawnattr_setflags(&attributes,
        POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) ||
        (error = posix_spawnattr_setsigmask(&attributes, &empty)) ||
        (error = posix_spawnattr_setsigdefault(&attributes, &defaults)) ||
        (error = inherit_descriptor(&actions, sources[0], STDIN_FILENO)) ||
        (error = inherit_descriptor(&actions, sources[1], STDOUT_FILENO)) ||
        (error = inherit_descriptor(&actions, sources[2], STDERR_FILENO)) ||
        (error = inherit_descriptor(&actions, sources[3], parent_lifeline))) goto fail_sources;
    for (size_t index = 0; index < mapping_count; ++index)
        if ((error = inherit_descriptor(&actions, sources[index + 5], mappings[index].target))) goto fail_sources;
    error = sources[4] >= 0 ? posix_spawn_file_actions_addfchdir_np(&actions, sources[4])
                              : posix_spawn_file_actions_addchdir(&actions, directory);
    if (error) goto fail_sources;
    error = posix_spawn(&child->pid, path, &actions, &attributes, argv, envp);
    if (error) goto fail_sources;
    for (size_t index = 0; index < source_count; ++index) if (sources[index] >= 0) close(sources[index]);
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(ends[0]);
    child->lifeline = ends[1];
    *result = child;
    ngv_bpy_spawn_unlock();
    return 0;
fail_sources:
    for (size_t index = 0; index < source_count; ++index) if (sources[index] >= 0) close(sources[index]);
    posix_spawnattr_destroy(&attributes);
fail_actions:
    posix_spawn_file_actions_destroy(&actions);
fail_pipe:
    close(ends[0]);
    close(ends[1]);
fail_mutex:
    pthread_mutex_destroy(&child->lock);
    free(child);
fail_lock:
    ngv_bpy_spawn_unlock();
    return error;
}

pid_t ngv_bpy_child_pid(ngv_bpy_child *child) { return child ? child->pid : -1; }

static int poll_locked(ngv_bpy_child *child, int *running) {
    *running = 0;
    if (child->reaped) return 0;
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    int result;
    do { result = waitid(P_PID, (id_t)child->pid, &info, WEXITED | WNOHANG | WNOWAIT); }
    while (result < 0 && errno == EINTR);
    if (result < 0) return errno;
    if (info.si_pid != 0 && info.si_pid != child->pid) return EIO;
    *running = info.si_pid == 0 || (info.si_code != CLD_EXITED &&
        info.si_code != CLD_KILLED && info.si_code != CLD_DUMPED);
    return 0;
}

int ngv_bpy_child_poll(ngv_bpy_child *child, int *running) {
    if (!child || !running) return EINVAL;
    pthread_mutex_lock(&child->lock);
    int error = poll_locked(child, running);
    pthread_mutex_unlock(&child->lock);
    return error;
}

int ngv_bpy_child_signal(ngv_bpy_child *child, int signal_number) {
    if (!child || (signal_number != SIGTERM && signal_number != SIGSTOP && signal_number != SIGKILL)) return EINVAL;
    pthread_mutex_lock(&child->lock);
    int running = 0;
    int error = poll_locked(child, &running);
    if (!error && running && kill(child->pid, signal_number) != 0) error = errno;
    pthread_mutex_unlock(&child->lock);
    return error;
}

int ngv_bpy_child_reap(ngv_bpy_child *child, int *reaped, int *exit_status, int *termination_signal) {
    if (!child || !reaped || !exit_status || !termination_signal) return EINVAL;
    pthread_mutex_lock(&child->lock);
    int error = 0;
    if (!child->reaped) {
        int status = 0;
        pid_t result;
        do { result = waitpid(child->pid, &status, WNOHANG); } while (result < 0 && errno == EINTR);
        if (result < 0) error = errno;
        else if (result == child->pid) {
            if (!WIFEXITED(status) && !WIFSIGNALED(status)) error = EIO;
            else {
                child->reaped = 1;
                child->termination_signal = WIFSIGNALED(status) ? WTERMSIG(status) : 0;
                child->exit_status = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
                close(child->lifeline);
                child->lifeline = -1;
            }
        } else if (result != 0) error = EIO;
    }
    *reaped = child->reaped;
    *exit_status = child->exit_status;
    *termination_signal = child->termination_signal;
    pthread_mutex_unlock(&child->lock);
    return error;
}

int ngv_bpy_child_destroy(ngv_bpy_child *child) {
    if (!child) return EINVAL;
    pthread_mutex_lock(&child->lock);
    int reaped = child->reaped;
    pthread_mutex_unlock(&child->lock);
    if (!reaped) return EBUSY;
    pthread_mutex_destroy(&child->lock);
    free(child);
    return 0;
}

int ngv_bpy_parent_alive(pid_t expected_parent) {
    if (expected_parent <= 1 || getppid() != expected_parent) return 0;
    struct pollfd descriptor = { .fd = parent_lifeline, .events = POLLIN | POLLHUP | POLLERR };
    int result;
    do { result = poll(&descriptor, 1, 0); } while (result < 0 && errno == EINTR);
    return result == 0 && getppid() == expected_parent;
}

void ngv_bpy_close_parent_lifeline(void) { close(parent_lifeline); }

void *ngv_bpy_allocate_memory_probe(size_t bytes) {
    if (bytes == 0 || bytes > 4 * 1024 * 1024) { errno = EINVAL; return NULL; }
    void *allocation = malloc(bytes);
    if (allocation == NULL) { errno = ENOMEM; return NULL; }
    volatile uint8_t *target = allocation;
    uint64_t state = (uint64_t)(uintptr_t)allocation ^ UINT64_C(0x9e3779b97f4a7c15);
    for (size_t index = 0; index < bytes; index++) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        target[index] = (uint8_t)state;
    }
    return allocation;
}
