#ifndef __APPLE__
#define _GNU_SOURCE
#endif
#include "SFTPPTY.h"
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <termios.h>
#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

pid_t sftp_spawn_pty(int *master, int input, int error, char *const argv[], char *const envp[]) {
    struct winsize size = { .ws_row = 24, .ws_col = 240 };
    // forkpty establishes a controlling terminal and foreground process group.
    pid_t pid = forkpty(master, NULL, NULL, &size);
    if (pid == 0) {
        if (dup2(input, STDIN_FILENO) < 0 || dup2(error, STDERR_FILENO) < 0)
            _exit(127);
        close(input);
        close(error);
        // Dispatch workers may block SIGALRM. exec preserves the signal mask,
        // so OpenSSH would print its initial meter but never refresh it.
        sigset_t signals;
        sigemptyset(&signals);
        if (sigprocmask(SIG_SETMASK, &signals, NULL) < 0)
            _exit(127);
        execve("/usr/bin/sftp", argv, envp);
        _exit(127);
    }
    if (pid > 0) fcntl(*master, F_SETFD, FD_CLOEXEC);
    return pid;
}

// Give non-transfer runs a private process group too, so cancellation stops SSH
// and closes its inherited pipes as well as stopping the SFTP parent.
pid_t sftp_spawn_pipes(int input, int output, int error, char *const argv[], char *const envp[]) {
    return opensftp_spawn_pipes("/usr/bin/sftp", input, output, error, argv, envp);
}

pid_t opensftp_spawn_pipes(const char *executable, int input, int output, int error, char *const argv[], char *const envp[]) {
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attributes;
    int result = posix_spawn_file_actions_init(&actions);
    if (result != 0) { errno = result; return -1; }
    result = posix_spawnattr_init(&attributes);
    if (result != 0) {
        posix_spawn_file_actions_destroy(&actions);
        errno = result;
        return -1;
    }
    pid_t pid = -1;
    short flags = POSIX_SPAWN_SETPGROUP;
#ifdef __APPLE__
    // Inherit only descriptors explicitly duplicated below. In particular,
    // inheriting the parent's stdin writer prevents --files-from=- seeing EOF.
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    if ((result = posix_spawn_file_actions_adddup2(&actions, input, STDIN_FILENO)) == 0 &&
        (result = posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO)) == 0 &&
        (result = posix_spawn_file_actions_adddup2(&actions, error, STDERR_FILENO)) == 0 &&
#ifndef __APPLE__
        // Apply after dup2 so the standard streams remain available.
        (result = posix_spawn_file_actions_addclosefrom_np(&actions, STDERR_FILENO + 1)) == 0 &&
#endif
        (result = posix_spawnattr_setflags(&attributes, flags)) == 0 &&
        (result = posix_spawnattr_setpgroup(&attributes, 0)) == 0) {
        result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp);
    }
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    if (result != 0) { errno = result; return -1; }
    return pid;
}

// A terminal on stdout makes rsync flush verbose lines without depending on
// version-specific buffering flags. stdin remains the binary manifest pipe;
// stderr stays separate, and the child has the usual private process group.
pid_t opensftp_spawn_output_pty(const char *executable, int *master, int input, int error, char *const argv[], char *const envp[]) {
    int slave;
    struct winsize size = { .ws_row = 24, .ws_col = 240 };
    if (openpty(master, &slave, NULL, NULL, &size) < 0) return -1;
    struct termios terminal;
    if (tcgetattr(slave, &terminal) < 0) {
        close(*master); close(slave); *master = -1;
        return -1;
    }
    terminal.c_oflag &= ~OPOST; // Preserve LF instead of translating to CRLF.
    if (tcsetattr(slave, TCSANOW, &terminal) < 0) {
        close(*master); close(slave); *master = -1;
        return -1;
    }
    fcntl(*master, F_SETFD, FD_CLOEXEC);
    pid_t pid = opensftp_spawn_pipes(executable, input, slave, error, argv, envp);
    close(slave);
    if (pid < 0) { close(*master); *master = -1; }
    return pid;
}

int sftp_wait(pid_t pid) {
    int status;
    while (waitpid(pid, &status, 0) < 0) {
        if (errno != EINTR) return -1;
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
