#include <arpa/inet.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

typedef int (*sandbox_init_fn)(const char *, unsigned long long, const char *const *, char **);
typedef void (*sandbox_free_fn)(char *);
typedef int (*sandbox_check_fn)(pid_t, const char *, int, ...);

static int directory(const char *path, char resolved[PATH_MAX]) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC);
    if (fd < 0) return -1;
    if (fcntl(fd, F_GETPATH, resolved) != 0) { close(fd); return -1; }
    return fd;
}

static int denied(int error) { return error == EPERM || error == EACCES; }

static int file_error(const char *path, int flags) {
    int fd = open(path, flags | O_NOFOLLOW | O_CLOEXEC);
    int error = fd < 0 ? errno : 0;
    if (fd >= 0) close(fd);
    return error;
}

int main(int argc, char **argv) {
    if (argc != 9) return 80;
    const char *mode = argv[1];
    int native = !strcmp(mode, "native-control") || !strcmp(mode, "native-sandbox");
    int python = !strcmp(mode, "python-control") || !strcmp(mode, "python-sandbox");
    int shell = !strcmp(mode, "exec-control") || !strcmp(mode, "exec-sandbox");
    int confined = !strcmp(mode, "native-sandbox") || !strcmp(mode, "python-sandbox") || !strcmp(mode, "exec-sandbox");
    if (!native && !python && !shell) return 80;
    char *end = NULL;
    long peer = strtol(argv[7], &end, 10);
    if (!end || *end || peer <= 1 || peer > INT_MAX) return 80;
    long port = strtol(argv[8], &end, 10);
    if (!end || *end || port <= 0 || port > 65535) return 80;
    char work[PATH_MAX], runtime[PATH_MAX], executable[PATH_MAX];
    int workfd = directory(argv[3], work), runtimefd = directory(argv[4], runtime);
    if (workfd < 0 || runtimefd < 0) return 80;
    if (snprintf(executable, sizeof(executable), "%s/python/bin/python3.13", runtime) >= (int)sizeof(executable)) return 80;
    if (fchdir(workfd) != 0) return 80;
    close(workfd); close(runtimefd);
    int profilefd = open(argv[2], O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    char profile[32768];
    if (profilefd < 0 || fstat(profilefd, &info) != 0 || !S_ISREG(info.st_mode)
        || info.st_size <= 0 || info.st_size >= (off_t)sizeof(profile)) return 80;
    ssize_t count = read(profilefd, profile, (size_t)info.st_size);
    close(profilefd);
    if (count != info.st_size) return 80;
    profile[count] = 0;
    if (confined) {
        sandbox_init_fn initialize = (sandbox_init_fn)dlsym(RTLD_DEFAULT, "sandbox_init_with_parameters");
        sandbox_free_fn release = (sandbox_free_fn)dlsym(RTLD_DEFAULT, "sandbox_free_error");
        sandbox_check_fn check = (sandbox_check_fn)dlsym(RTLD_DEFAULT, "sandbox_check");
        if (!initialize || !release || !check) {
            void *library = dlopen("/usr/lib/libsandbox.dylib", RTLD_NOW);
            if (library) {
                initialize = (sandbox_init_fn)dlsym(library, "sandbox_init_with_parameters");
                release = (sandbox_free_fn)dlsym(library, "sandbox_free_error");
                check = (sandbox_check_fn)dlsym(library, "sandbox_check");
            }
        }
        if (!initialize || !release || !check) return 81;
        int before = check(getpid(), NULL, 0);
        printf("NGV_COMPONENT {\"stage\":\"before-sandbox\",\"pid\":%d,\"sandboxed\":%d}\n", getpid(), before);
        fflush(stdout);
        if (before != 0) return 85;
        const char *parameters[] = {"WORK", work, "RUNTIME", runtime, "PYTHON", executable, NULL};
        char *error = NULL;
        errno = 0;
        int result = initialize(profile, 0, parameters, &error);
        int failure = errno;
        printf("NGV_COMPONENT {\"stage\":\"sandbox\",\"pid\":%d,\"result\":%d,\"errno\":%d}\n", getpid(), result, failure);
        fflush(stdout);
        if (error) { fprintf(stderr, "sandbox profile: %s\n", error); release(error); }
        if (result != 0) return 82;
        int after = check(getpid(), NULL, 0);
        printf("NGV_COMPONENT {\"stage\":\"after-sandbox\",\"pid\":%d,\"sandboxed\":%d}\n", getpid(), after);
        fflush(stdout);
        if (after != 1) return 85;
    }
    if (native) {
        int read_error = file_error(argv[5], O_RDONLY);
        int write_error = file_error(argv[5], O_WRONLY);
        int allowed = open("allowed-native.txt", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        int allowed_error = allowed < 0 ? errno : 0;
        if (allowed >= 0) { if (write(allowed, "allowed", 7) != 7) allowed_error = errno ? errno : EIO; close(allowed); }
        errno = 0;
        pid_t child = fork();
        int fork_error = child < 0 ? errno : 0;
        if (child == 0) _exit(0);
        if (child > 0) {
            int status = 0;
            pid_t reaped;
            do { reaped = waitpid(child, &status, 0); } while (reaped < 0 && errno == EINTR);
            if (reaped != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) return 83;
        }
        int socketfd = socket(AF_INET, SOCK_STREAM, 0);
        int network_error = socketfd < 0 ? errno : 0;
        if (socketfd >= 0) {
            struct sockaddr_in address = {.sin_family = AF_INET, .sin_port = htons((unsigned short)port)};
            address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            if (connect(socketfd, (struct sockaddr *)&address, sizeof(address)) != 0) network_error = errno;
            close(socketfd);
        }
        errno = 0;
        int signal_error = kill((pid_t)peer, SIGUSR1) < 0 ? errno : 0;
        printf("NGV_COMPONENT {\"stage\":\"denials\",\"pid\":%d,\"confined\":%s,\"readErrno\":%d,\"writeErrno\":%d,"
               "\"forkErrno\":%d,\"networkErrno\":%d,\"signalErrno\":%d,\"allowedWriteErrno\":%d}\n",
               getpid(), confined ? "true" : "false", read_error, write_error, fork_error, network_error, signal_error, allowed_error);
        if (allowed_error) return 83;
        int passed = confined ? denied(read_error) && denied(write_error) && denied(fork_error)
                                && denied(network_error) && denied(signal_error)
                              : !(read_error || write_error || fork_error || network_error || signal_error);
        return passed ? 0 : 83;
    }
    if (shell) {
        char *arguments[] = {"/bin/sh", "-c", "exit 93", NULL};
        execv(arguments[0], arguments);
        int failure = errno;
        printf("NGV_COMPONENT {\"stage\":\"exec-denial\",\"pid\":%d,\"errno\":%d}\n", getpid(), failure);
        return confined && denied(failure) ? 0 : 84;
    }
    char *arguments[] = {executable, "-I", "-S", "-B", argv[6], NULL};
    execv(executable, arguments);
    fprintf(stderr, "Python exec failed: %d\n", errno);
    return 84;
}
