#ifdef __linux__

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/prctl.h>
#include <sys/wait.h>
#include <unistd.h>

static void msg(const char *msg, const char *arg) {
  if (write(STDERR_FILENO, msg, strlen(msg)) != 0) {
  }
  if (write(STDERR_FILENO, arg, strlen(arg)) != 0) {
  }
  if (write(STDERR_FILENO, "\n", 1) != 0) {
  }
}

static char binpath[512]; // NOLINT
static char pid_s[11];    // NOLINT

static void get_pid_binpath() {
  pid_t pid = getpid();
  sprintf(pid_s, "%d", pid); // NOLINT
  size_t ret = readlink("/proc/self/exe", binpath, 511);
  if (ret < 0)
    return;
  binpath[ret] = 0; // NOLINT
}

static const auto lldb{"/usr/bin/lldb"};
static const auto default_debugger{"/usr/bin/gdbserver"};

static auto get_debugger() -> const char * {
  const char *debugger = secure_getenv("JITDEBUG");
  if (not debugger)
    return default_debugger;
  if (strcmp(debugger, "on") == 0)
    return default_debugger;
  if (strcmp(debugger, "1") == 0)
    return default_debugger;
  if (strcmp(debugger, "true") == 0)
    return default_debugger;
  return debugger;
}
const char *const debugger = get_debugger();

void start_debugger(const char * dbg, const char **argv) {
#if defined(PR_SET_PTRACER)
  prctl(PR_SET_PTRACER, PR_SET_PTRACER_ANY, 0, 0, 0); // NOLINT
#endif
  int child_pid = fork();
  if (!child_pid) {
    dup2(2, 1); // redirect output to stderr
    msg("debugging with ", dbg);
    execv(dbg, const_cast<char *const *>(argv)); // NOLINT
    _exit(1);
  } else {
    int stat(0);
    waitpid(child_pid, &stat, 0);
  }
}

extern "C" void sighdl_debugger(int no, siginfo_t * /*sigi*/, void * /*uco*/) {
  get_pid_binpath();
  const char *argv[] = {// NOLINT
                        debugger, "--attach", "[::1]:7777", pid_s, nullptr};
  start_debugger(debugger, argv);
  (void)raise(no);
}

extern "C" void sighdl_backtrace(int no, siginfo_t * /*sigi*/, void * /*uco*/) {
  get_pid_binpath();
  const char *argv[] = {// NOLINT
                        lldb,     "--batch", "-p",    pid_s,
                        "--one-line", "bt",      binpath, nullptr};
  start_debugger(lldb, argv);
  (void)raise(no);
}

static void install_crash_handler(void (*hdlr)(int, siginfo_t *, void *)) {
  struct sigaction action {};
  sigemptyset(&action.sa_mask);
  action.sa_flags = SA_SIGINFO | SA_RESETHAND;
#ifdef SA_FULLDUMP
  action.sa_flags |= SA_FULLDUMP;
#endif
  action.sa_sigaction = hdlr;
  sigaction(SIGBUS, &action, nullptr);
  sigaction(SIGSEGV, &action, nullptr);
  sigaction(SIGABRT, &action, nullptr);
  sigaction(SIGTRAP, &action, nullptr);
  sigaction(SIGFPE, &action, nullptr);
}

extern "C" void install_debugger() { install_crash_handler(sighdl_debugger); }
extern "C" void install_backtrace() { install_crash_handler(sighdl_backtrace); }
extern "C" void install_jitdebugger() {
  if (secure_getenv("JITDEBUG"))
    install_debugger();
  else
    install_backtrace();
}

#else

extern "C" void install_debugger() {}
extern "C" void install_backtrace() {}
extern "C" void install_jitdebugger() {}

#endif
