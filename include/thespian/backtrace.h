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

#ifdef __cplusplus
}
#endif
