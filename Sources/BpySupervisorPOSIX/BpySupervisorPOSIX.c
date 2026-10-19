#include "BpySupervisorPOSIX.h"
#include <errno.h>
#include <sys/wait.h>
#include <unistd.h>

int ngv_bpy_probe_fork(int *fork_errno) {
    if (fork_errno == NULL) return EINVAL;
    *fork_errno = 0;
    errno = 0;
    pid_t child = fork();
    if (child == 0) _exit(0);
    if (child < 0) {
        *fork_errno = errno;
        return 0;
    }
    int status = 0;
    pid_t waited;
    do {
        waited = waitpid(child, &status, 0);
    } while (waited < 0 && errno == EINTR);
    if (waited != child) return waited < 0 ? errno : EIO;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : EIO;
}
