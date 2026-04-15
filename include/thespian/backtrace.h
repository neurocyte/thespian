#pragma once

#ifdef __cplusplus
#include <csignal>
extern "C" {
#else
#include <signal.h>
#endif

void install_debugger();
void install_remote_debugger();
void install_backtrace();
void install_jitdebugger();

#if !defined(_WIN32)
void sighdl_debugger(int no, siginfo_t * /*sigi*/, void * /*uco*/);
void sighdl_remote_debugger(int no, siginfo_t * /*sigi*/, void * /*uco*/);
void sighdl_backtrace(int no, siginfo_t * /*sigi*/, void * /*uco*/);
#endif

#ifdef __cplusplus
}
#endif
