#include "BpySupervisorPOSIX.h"
#include <errno.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static double now(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1e9;
}

static void snapshot(ngv_bpy_child *child, const char *stage, int result) {
    pid_t pid = ngv_bpy_child_pid(child);
    int running = -1;
    int poll_error = ngv_bpy_child_poll(child, &running);
    siginfo_t info = {0};
    errno = 0;
    int waited = waitid(P_PID, pid, &info, WEXITED | WSTOPPED | WNOHANG | WNOWAIT);
    int wait_error = waited < 0 ? errno : 0;
    struct proc_bsdinfo bsd = {0};
    errno = 0;
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, sizeof(bsd));
    int proc_error = size <= 0 ? errno : 0;
    printf("{\"stage\":\"%s\",\"monotonic\":%.6f,\"pid\":%d,\"result\":%d,"
           "\"pollError\":%d,\"running\":%d,\"waitError\":%d,\"waitPID\":%d,"
           "\"waitCode\":%d,\"waitStatus\":%d,\"procBytes\":%d,\"procError\":%d,"
           "\"procStatus\":%u,\"parentPID\":%u}\n",
           stage, now(), pid, result, poll_error, running, wait_error, info.si_pid,
           info.si_code, info.si_status, size, proc_error, bsd.pbi_status, bsd.pbi_ppid);
    fflush(stdout);
}

static int reap(ngv_bpy_child *child, double duration, int *status, int *signal_number) {
    double deadline = now() + duration;
    do {
        int reaped = 0;
        int error = ngv_bpy_child_reap(child, &reaped, status, signal_number);
        if (error || reaped) return error;
        struct timespec pause = {.tv_nsec = 5000000};
        nanosleep(&pause, NULL);
    } while (now() < deadline);
    return ETIMEDOUT;
}

static int run_case(int mode, int iteration) {
    int output[2];
    if (pipe(output) != 0) return errno;
    char *script = mode == 0 ? "printf ready; while :; do :; done"
                            : "trap '' TERM; printf ready; while :; do :; done";
    char *argv[] = {"/bin/sh", "-c", script, NULL};
    char *env[] = {NULL};
    ngv_bpy_child *child = NULL;
    int error = ngv_bpy_child_spawn("/bin/sh", argv, env, "/", -1, output[1], STDERR_FILENO, &child);
    close(output[1]);
    printf("{\"stage\":\"spawn\",\"mode\":%d,\"iteration\":%d,\"error\":%d}\n", mode, iteration, error);
    fflush(stdout);
    if (error) { close(output[0]); return error; }
    int status = 0, signal_number = 0;
    struct pollfd descriptor = {.fd = output[0], .events = POLLIN};
    char ready[5];
    if (poll(&descriptor, 1, 3000) != 1 || !(descriptor.revents & POLLIN)
        || read(output[0], ready, sizeof(ready)) != (ssize_t)sizeof(ready) || memcmp(ready, "ready", 5)) {
        error = EIO;
        goto cleanup;
    }
    snapshot(child, "ready", 0);
    error = ngv_bpy_child_signal(child, SIGTERM);
    snapshot(child, "term", error);
    if (error) goto cleanup;
    error = reap(child, .25, &status, &signal_number);
    if (mode == 0) {
        if (!error && (status != 128 + SIGTERM || signal_number != SIGTERM)) error = EIO;
        goto cleanup;
    }
    snapshot(child, "term-grace", error);
    if (error != ETIMEDOUT) { error = EIO; goto cleanup; }
    if (mode >= 2) {
        error = ngv_bpy_child_signal(child, SIGSTOP);
        if (error) goto cleanup;
    }
    if (mode == 3) {
        double deadline = now() + 3;
        while (1) {
            siginfo_t stopped = {0};
            if (waitid(P_PID, ngv_bpy_child_pid(child), &stopped, WSTOPPED | WNOHANG | WNOWAIT) < 0) {
                if (errno == EINTR) continue;
                error = errno;
                goto cleanup;
            }
            if (stopped.si_pid == ngv_bpy_child_pid(child) && stopped.si_code == CLD_STOPPED) break;
            if (now() >= deadline) { error = ETIMEDOUT; goto cleanup; }
            struct timespec pause = {.tv_nsec = 5000000};
            nanosleep(&pause, NULL);
        }
        int running = 0;
        error = ngv_bpy_child_poll(child, &running);
        snapshot(child, "stopped-owned", error);
        if (!error && !running) error = EIO;
        if (error) goto cleanup;
    }
    error = ngv_bpy_child_signal(child, SIGKILL);
    if (mode >= 2) printf("{\"stage\":\"stop-result\",\"error\":0}\n");
    snapshot(child, "kill", error);
    if (error) goto cleanup;
    error = reap(child, 2, &status, &signal_number);
    if (!error && (status != 128 + SIGKILL || signal_number != SIGKILL)) error = EIO;
cleanup:
    printf("{\"stage\":\"case-result\",\"mode\":%d,\"iteration\":%d,\"error\":%d,"
           "\"exitStatus\":%d,\"terminationSignal\":%d}\n", mode, iteration, error, status, signal_number);
    fflush(stdout);
    if (error) {
        snapshot(child, "failure", error);
        int killed = ngv_bpy_child_signal(child, SIGKILL);
        snapshot(child, "cleanup-kill", killed);
        int cleaned = reap(child, 3, &status, &signal_number);
        printf("{\"stage\":\"cleanup\",\"error\":%d}\n", cleaned);
    }
    close(output[0]);
    int destroyed = ngv_bpy_child_destroy(child);
    printf("{\"stage\":\"destroy\",\"error\":%d}\n", destroyed);
    fflush(stdout);
    return error ? error : destroyed;
}

int main(void) {
    for (int iteration = 0; iteration < 3; iteration++) {
        for (int mode = 0; mode < 4; mode++) {
            int error = run_case(mode, iteration);
            if (error) return 1;
        }
    }
    puts("{\"stage\":\"complete\",\"cases\":12}");
    return 0;
}
