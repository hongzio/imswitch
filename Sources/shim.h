// The one thing Swift will not hand over.
//
// Swift's Darwin module marks fork() unavailable and points at posix_spawn
// instead. The hazard behind that is real — a forked child of a process with
// Cocoa and Carbon loaded may only make async-signal-safe calls — but
// posix_spawn cannot order setsid before the pty slave is opened, which is
// exactly what a controlling terminal needs on macOS. Remote.startChild
// answers the hazard instead of avoiding it: nothing but system calls runs
// between this fork and the execvp that follows it.

#include <unistd.h>

static inline pid_t imswitch_fork(void) { return fork(); }
