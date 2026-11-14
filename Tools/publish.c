#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/stdio.h>
#include <unistd.h>

#ifdef DOCKMAL_PUBLICATION_TESTING
#include <signal.h>
static void pause_for_test(const char *phase) {
    const char *requested = getenv("DOCKMAL_TEST_PAUSE_AT");
    if (requested && strcmp(requested, phase) == 0) {
        fprintf(stderr, "PUBLICATION_PAUSED %d %s\n", getpid(), phase);
        fflush(stderr);
        raise(SIGSTOP);
    }
}
#else
#define pause_for_test(phase) ((void)0)
#endif

/* The lock file is permanent. Never unlink it: waiters must share one inode.
 * The kernel releases flock when the publisher exits, including SIGKILL.
 * Bundle replacement uses one filesystem operation, so there is no missing-app
 * interval and no rollback transaction to recover after a killed publisher. */
int main(int argc, char **argv) {
    if (argc != 3 && argc != 4) {
        fprintf(stderr, "Usage: publish check OUTPUT | publish replace STAGED OUTPUT\n");
        return 2;
    }
    int checking = argc == 3 && strcmp(argv[1], "check") == 0;
    if (!checking && !(argc == 4 && strcmp(argv[1], "replace") == 0)) return 2;
    const char *output = argv[argc - 1];
    char *lock_path = NULL;
    if (asprintf(&lock_path, "%s.build-lock", output) < 0) return 1;
    struct stat info;
    if (lstat(lock_path, &info) == 0 && S_ISDIR(info.st_mode)) {
        fprintf(stderr, "Legacy output lock directory: %s\n"
                "Ensure no older build is running. If the output is missing, recover\n"
                "the previous app from a sibling .dock-double-click.*/old directory\n"
                "before removing this legacy lock directory manually.\n", lock_path);
        free(lock_path);
        return 1;
    }
    int fd = open(lock_path, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (fd < 0 || fstat(fd, &info) != 0 || !S_ISREG(info.st_mode) || info.st_nlink != 1) {
        fprintf(stderr, "Cannot open a regular output lock file: %s\n", lock_path);
        if (fd >= 0) close(fd);
        free(lock_path);
        return 1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        fprintf(stderr, "Output publication is busy: %s (%s). Retry after it finishes; "
                "do not delete the lock file.\n", lock_path, strerror(errno));
        close(fd);
        free(lock_path);
        return 1;
    }
    free(lock_path);
    if (checking) { close(fd); return 0; }

    if (lstat(argv[2], &info) != 0 || !S_ISDIR(info.st_mode)) {
        fprintf(stderr, "Staged app must be a directory, not a symlink.\n");
        close(fd);
        return 1;
    }
    unsigned int flags;
    if (lstat(output, &info) == 0) {
        if (!S_ISDIR(info.st_mode)) {
            fprintf(stderr, "Output changed during the build; refusing to replace it.\n");
            close(fd);
            return 1;
        }
        flags = RENAME_SWAP;
    } else if (errno == ENOENT) {
        flags = RENAME_EXCL;
    } else {
        perror("Cannot inspect output");
        close(fd);
        return 1;
    }
    pause_for_test("before");
    int result = renameatx_np(AT_FDCWD, argv[2], AT_FDCWD, output, flags);
    if (result == 0) pause_for_test("after");
    if (result != 0) perror("Atomic app publication failed; existing output was preserved");
    close(fd);
    return result == 0 ? 0 : 1;
}
