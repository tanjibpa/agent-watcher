// Reproduce Ghostty's macOS login-shell chain without controlling a terminal app.
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

int main(int argc, char **argv) {
  if (argc != 5) return 2;
  if (strcmp(argv[1], "terminal") == 0) {
    int master;
    pid_t child = forkpty(&master, NULL, NULL, NULL);
    if (child < 0) return 3;
    if (child == 0) {
      struct passwd *user = getpwuid(getuid());
      if (!user) _exit(4);
      execl("/usr/bin/login", "login", "-flp", user->pw_name,
            argv[2], "cli", argv[2], argv[3], argv[4], NULL);
      _exit(5);
    }
    alarm(10);
    char buffer[4096];
    ssize_t count;
    while ((count = read(master, buffer, sizeof(buffer))) > 0) {
      if (write(STDOUT_FILENO, buffer, count) < 0) break;
    }
    close(master);
    int status;
    if (waitpid(child, &status, 0) < 0 || !WIFEXITED(status)) return 6;
    return WEXITSTATUS(status);
  }

  if (getenv("AGENT_WATCHER_TEST_PIPE_INPUT")) {
    if (!freopen("/dev/null", "r", stdin)) return 7;
  }
  int input[2];
  if (pipe(input) != 0) return 7;
  pid_t child = fork();
  if (child < 0) return 8;
  if (child == 0) {
    close(input[1]);
    dup2(input[0], STDIN_FILENO);
    close(input[0]);
    execl(argv[3], argv[3], argv[4], NULL);
    _exit(9);
  }
  close(input[0]);
  char payload[256];
  if (strcmp(argv[4], "pi") == 0) {
    snprintf(payload, sizeof(payload),
             "{\"session_id\":\"login-test\",\"cwd\":\"/tmp\","
             "\"hook_event_name\":\"SessionStart\",\"cli_pid\":%d}", getpid());
  } else {
    snprintf(payload, sizeof(payload),
             "{\"session_id\":\"login-test\",\"cwd\":\"/tmp\","
             "\"hook_event_name\":\"SessionStart\"}");
  }
  ssize_t written = write(input[1], payload, strlen(payload));
  close(input[1]);
  int status;
  if (waitpid(child, &status, 0) < 0 || !WIFEXITED(status)) return 10;
  return written == (ssize_t)strlen(payload) ? WEXITSTATUS(status) : 11;
}
