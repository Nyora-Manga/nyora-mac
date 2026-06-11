// ConcurrencyShim.c
//
// macOS 26.2 Tahoe beta workaround for a crash in swift_task_isMainExecutorImpl.
//
// Root cause: on macOS 26.2 + Xcode 26.5 SDK the main actor executor object has
// corrupted ObjC metadata (isa slot = 0x0 / 0x1ff38 / 0x220).  Every path that
// evaluates @MainActor isolation in a view body goes through:
//
//   swift_task_isCurrentExecutorWithFlags  (public API, called by SwiftUI)
//     -> swift_task_isCurrentExecutorWithFlagsImpl
//     -> SerialExecutorRef::isMainExecutor()
//     -> swift_task_isMainExecutorImpl         <- reads corrupted isa -> CRASH
//
// Fix: replace both public-API entry points with safe thread-test equivalents.
// The main actor always runs on the main thread, so pthread_main_np() is
// semantically correct for every executor check SwiftUI ever performs.
//
// Mechanism: DYLD compile-time interpose (__DATA,__interpose).  When this
// object is linked into the Nyora executable, dyld rewires all import-table
// call sites for the two symbols — including those in libSwiftUI.dylib and
// libswift_Concurrency.dylib — before any Swift code executes.

#include <pthread.h>
#include <stdbool.h>

// ── swift_task_isCurrentExecutorWithFlags ──────────────────────────────────
// Swift CC on ARM64 for SerialExecutorRef{identity, impl} + flags:
//   x0 = identity (void*)
//   x1 = impl     (unsigned long)
//   x2 = flags    (unsigned long)
//   returns bool in x0

extern bool swift_task_isCurrentExecutorWithFlags(
    void *identity, unsigned long impl, unsigned long flags);

static bool nyora_isCurrentExecutorWithFlags(
    void *identity, unsigned long impl, unsigned long flags) {
    return pthread_main_np() != 0;
}

// ── swift_task_isMainExecutor ──────────────────────────────────────────────
// x0 = identity, x1 = impl, returns bool in x0

extern bool swift_task_isMainExecutor(void *identity, unsigned long impl);

static bool nyora_isMainExecutor(void *identity, unsigned long impl) {
    return pthread_main_np() != 0;
}

// ── DYLD interpose table ───────────────────────────────────────────────────
typedef struct { const void *replacement; const void *replacee; } NYInterpose;

__attribute__((used, section("__DATA,__interpose")))
static const NYInterpose nyora_interpose_table[2] = {
    { (const void *)nyora_isCurrentExecutorWithFlags,
      (const void *)swift_task_isCurrentExecutorWithFlags },
    { (const void *)nyora_isMainExecutor,
      (const void *)swift_task_isMainExecutor },
};
