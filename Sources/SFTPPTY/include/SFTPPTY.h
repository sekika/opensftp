#include <sys/types.h>
// argv/envp are prepared before forking; the child configures FDs/signals and execs.
pid_t sftp_spawn_pty(int *master, int input, int error, char *const argv[], char *const envp[]);
pid_t sftp_spawn_pipes(int input, int output, int error, char *const argv[], char *const envp[]);
pid_t opensftp_spawn_pipes(const char *executable, int input, int output, int error, char *const argv[], char *const envp[]);
pid_t opensftp_spawn_output_pty(const char *executable, int *master, int input, int error, char *const argv[], char *const envp[]);
int sftp_wait(pid_t pid);
