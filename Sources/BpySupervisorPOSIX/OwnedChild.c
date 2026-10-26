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

enum { parent_lifeline = 198 };

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
    if (!path || !argv || !envp || !directory || !result) return EINVAL;
    *result = NULL;
    struct sigaction child_signal;
    if (sigaction(SIGCHLD, NULL, &child_signal) != 0) return errno;
    if (child_signal.sa_handler == SIG_IGN || (child_signal.sa_flags & SA_NOCLDWAIT)) return EINVAL;
    struct rlimit descriptors;
    if (getrlimit(RLIMIT_NOFILE, &descriptors) != 0) return errno;
    if (descriptors.rlim_cur <= parent_lifeline) return EMFILE;
    ngv_bpy_child *child = calloc(1, sizeof(*child));
    if (!child) return ENOMEM;
    int error = pthread_mutex_init(&child->lock, NULL);
    if (error) { free(child); return error; }
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
    if ((error = posix_spawnattr_setflags(&attributes,
        POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF)) ||
        (error = posix_spawnattr_setsigmask(&attributes, &empty)) ||
        (error = posix_spawnattr_setsigdefault(&attributes, &defaults)) ||
        (error = inherit_descriptor(&actions, input, STDIN_FILENO)) ||
        (error = inherit_descriptor(&actions, output, STDOUT_FILENO)) ||
        (error = inherit_descriptor(&actions, errors, STDERR_FILENO)) ||
        (error = inherit_descriptor(&actions, ends[0], parent_lifeline)) ||
        (error = posix_spawn_file_actions_addchdir(&actions, directory))) goto fail_attributes;
    error = posix_spawn(&child->pid, path, &actions, &attributes, argv, envp);
    if (error) goto fail_attributes;
    posix_spawnattr_destroy(&attributes);
    posix_spawn_file_actions_destroy(&actions);
    close(ends[0]);
    child->lifeline = ends[1];
    *result = child;
    return 0;
fail_attributes:
    posix_spawnattr_destroy(&attributes);
fail_actions:
    posix_spawn_file_actions_destroy(&actions);
fail_pipe:
    close(ends[0]);
    close(ends[1]);
fail_mutex:
    pthread_mutex_destroy(&child->lock);
    free(child);
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
    *running = info.si_pid == 0;
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
