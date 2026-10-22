/* The process edge's C: what bd needs from the operating system beyond the
   Goose os library. Files with modes, directories, an exclusive lock, a
   durable append, the working directory, and child processes whose output
   is captured. Strings arrive as Goose slices (not NUL-terminated) and
   results go back through Goose builders. POSIX only. */

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "goose.h"

extern char **environ;

typedef struct { const uint8_t *data; int64_t len; } bd_slice;

/* A NUL-terminated copy of s in buf, or 0 if it does not fit. */
static const char *cstr(bd_slice s, char *buf, size_t cap) {
    if (s.len < 0 || (size_t)s.len >= cap) return 0;
    memcpy(buf, s.data, (size_t)s.len);
    buf[s.len] = 0;
    return buf;
}

uint8_t bd_sys_getcwd(gs_rref out) {
    char buf[PATH_MAX];
    if (!getcwd(buf, sizeof buf)) return 0;
    gs_bld_append(out, buf, (int64_t)strlen(buf));
    return 1;
}

uint8_t bd_sys_chdir(bd_slice path) {
    char p[PATH_MAX];
    return cstr(path, p, sizeof p) && chdir(p) == 0;
}

/* The canonical absolute path of an existing file or directory. */
uint8_t bd_sys_realpath(bd_slice path, gs_rref out) {
    char p[PATH_MAX], r[PATH_MAX];
    if (!cstr(path, p, sizeof p) || !realpath(p, r)) return 0;
    gs_bld_append(out, r, (int64_t)strlen(r));
    return 1;
}

/* A directory with the given permission bits (less the umask); true if one
   is there afterwards. */
uint8_t bd_sys_mkdir(bd_slice path, int64_t mode) {
    char p[PATH_MAX];
    struct stat st;
    if (!cstr(path, p, sizeof p)) return 0;
    if (mkdir(p, (mode_t)mode) == 0) return 1;
    return errno == EEXIST && stat(p, &st) == 0 && S_ISDIR(st.st_mode);
}

static int write_all(int fd, const uint8_t *d, int64_t n) {
    while (n > 0) {
        ssize_t w = write(fd, d, (size_t)n);
        if (w < 0) {
            if (errno == EINTR) continue;
            return 0;
        }
        d += w;
        n -= w;
    }
    return 1;
}

/* Writes (or appends) data to path, creating it with the permission bits
   given (less the umask) as Go's os.WriteFile does. With sync, the data is
   on disk before this returns. */
uint8_t bd_sys_write_file(bd_slice path, bd_slice data, int64_t mode, uint8_t append, uint8_t sync) {
    char p[PATH_MAX];
    if (!cstr(path, p, sizeof p)) return 0;
    int flags = O_WRONLY | O_CREAT | O_CLOEXEC | (append ? O_APPEND : O_TRUNC);
    int fd = open(p, flags, (mode_t)mode);
    if (fd < 0) return 0;
    int ok = write_all(fd, data.data, data.len);
    if (ok && sync) ok = fsync(fd) == 0;
    return close(fd) == 0 && ok;
}

/* Replaces path with data in one step: a temporary file beside it, synced,
   given the mode, and renamed over it. */
uint8_t bd_sys_replace_file(bd_slice path, bd_slice data, int64_t mode) {
    char p[PATH_MAX], t[PATH_MAX + 16];
    if (!cstr(path, p, sizeof p)) return 0;
    snprintf(t, sizeof t, "%s.%d.tmp", p, (int)getpid());
    int fd = open(t, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, (mode_t)mode);
    if (fd < 0) return 0;
    int ok = write_all(fd, data.data, data.len) && fsync(fd) == 0;
    ok = close(fd) == 0 && ok;
    if (ok) ok = rename(t, p) == 0;
    if (!ok) unlink(t);
    return ok;
}

/* Takes an exclusive lock on path (created with mode if missing), waiting
   for any other holder: the descriptor, which holds the lock until the
   process exits, or -1. */
int64_t bd_sys_lock(bd_slice path, int64_t mode) {
    char p[PATH_MAX];
    if (!cstr(path, p, sizeof p)) return -1;
    int fd = open(p, O_RDWR | O_CREAT | O_CLOEXEC, (mode_t)mode);
    if (fd < 0) return -1;
    while (flock(fd, LOCK_EX) != 0) {
        if (errno != EINTR) {
            close(fd);
            return -1;
        }
    }
    return fd;
}

/* 0 for none, 1 for a regular file, 2 for a directory, 3 for anything else. */
int64_t bd_sys_kind(bd_slice path) {
    char p[PATH_MAX];
    struct stat st;
    if (!cstr(path, p, sizeof p) || stat(p, &st) != 0) return 0;
    if (S_ISREG(st.st_mode)) return 1;
    if (S_ISDIR(st.st_mode)) return 2;
    return 3;
}

uint8_t bd_sys_isatty(int64_t fd) { return isatty((int)fd) == 1; }

/* Whether standard input comes from a pipe or a file rather than a terminal
   or a device such as /dev/null: what Go reads as a mode without
   os.ModeCharDevice. */
uint8_t bd_sys_stdin_redirected(void) {
    struct stat st;
    if (fstat(0, &st) != 0) return 0;
    return !S_ISCHR(st.st_mode);
}

/* Runs a program found on PATH. argv holds the arguments, each ended by a
   NUL byte; dir, if not empty, is the working directory to run it in.
   Its stdout and stderr are appended to out and err; stdin is /dev/null.
   The exit status, or -1 if it could not be run. */
int64_t bd_sys_run(bd_slice argv, bd_slice dir, gs_rref out, gs_rref err) {
    enum { MAXARGS = 64 };
    char *args[MAXARGS + 1];
    char *buf = malloc((size_t)argv.len + 1);
    if (!buf) return -1;
    memcpy(buf, argv.data, (size_t)argv.len);
    buf[argv.len] = 0;
    int n = 0;
    for (int64_t i = 0; i < argv.len && n < MAXARGS;) {
        args[n++] = buf + i;
        while (i < argv.len && buf[i]) i++;
        i++;
    }
    args[n] = 0;
    if (n == 0) { free(buf); return -1; }

    char cwd[PATH_MAX];
    if (dir.len > 0 && !cstr(dir, cwd, sizeof cwd)) { free(buf); return -1; }

    int po[2], pe[2];
    if (pipe2(po, O_CLOEXEC) != 0) { free(buf); return -1; }
    if (pipe2(pe, O_CLOEXEC) != 0) { close(po[0]); close(po[1]); free(buf); return -1; }

    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, po[1], 1);
    posix_spawn_file_actions_adddup2(&fa, pe[1], 2);
    if (dir.len > 0) posix_spawn_file_actions_addchdir_np(&fa, cwd);

    pid_t pid;
    int rc = posix_spawnp(&pid, args[0], &fa, 0, args, environ);
    posix_spawn_file_actions_destroy(&fa);
    close(po[1]);
    close(pe[1]);
    free(buf);
    if (rc != 0) { close(po[0]); close(pe[0]); return -1; }

    struct pollfd fds[2] = {{po[0], POLLIN, 0}, {pe[0], POLLIN, 0}};
    gs_rref sinks[2] = {out, err};
    int open_fds = 2;
    char chunk[65536];
    while (open_fds > 0) {
        if (poll(fds, 2, -1) < 0) {
            if (errno == EINTR) continue;
            break;
        }
        for (int i = 0; i < 2; i++) {
            if (fds[i].fd < 0 || !(fds[i].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            ssize_t r = read(fds[i].fd, chunk, sizeof chunk);
            if (r > 0) {
                gs_bld_append(sinks[i], chunk, r);
            } else if (r == 0 || errno != EINTR) {
                close(fds[i].fd);
                fds[i].fd = -1;
                open_fds--;
            }
        }
    }
    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    return 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
}
