#ifndef NGV_BPY_SUPERVISOR_POSIX_H
#define NGV_BPY_SUPERVISOR_POSIX_H

#include <sys/types.h>

int ngv_bpy_probe_fork(int *fork_errno);

typedef struct ngv_bpy_child ngv_bpy_child;
int ngv_bpy_child_spawn(const char *path, char *const argv[], char *const envp[],
    const char *directory, int input, int output, int errors, ngv_bpy_child **child);
pid_t ngv_bpy_child_pid(ngv_bpy_child *child);
int ngv_bpy_child_poll(ngv_bpy_child *child, int *running);
int ngv_bpy_child_signal(ngv_bpy_child *child, int signal_number);
int ngv_bpy_child_reap(ngv_bpy_child *child, int *reaped, int *exit_status, int *termination_signal);
int ngv_bpy_child_destroy(ngv_bpy_child *child);
int ngv_bpy_parent_alive(pid_t expected_parent);
void ngv_bpy_close_parent_lifeline(void);

#endif
