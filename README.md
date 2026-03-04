# Thespian

Fast & flexible actors for Zig, C & C++ applications

To build:

```
zig build
```

See `tests/*` for many interesting examples.

To run the tests:
```
zig build test
```

---

## Architecture Overview

Thespian is an actor framework where concurrent units ("instances")
communicate exclusively via message passing, with no shared mutable state.
Messages are encoded using **CBOR** (Concise Binary Object Representation).

The library has three layers:

1. **C++ core** - the primary implementation (`src/instance.cpp`, `src/executor_asio.cpp`, `src/hub.cpp`)
2. **C API** - a thin wrapper layer in `src/c/` exposing the C++ core to other languages
3. **Zig module** - `src/thespian.zig` wraps the C API into idiomatic Zig types with comptime features

---

## Key Concepts

**`context`** - the runtime environment. You create one, spawn actors into
it, then call `run()`. It owns the executor thread pool.

**`instance` / actor** - each spawned actor is a `behaviour` (a
`std::function<result()>`) that registers a `receiver` to handle incoming
messages. Actors run on an executor. Currently the only executor provided
in this repo is one backed by ASIO.

**`handle` / `pid`** - a reference to a live actor. In C++ this is
`thespian::handle`; in Zig it is `pid` (owned) or `pid_ref` (borrowed).
Sending to an expired handle is safe and fails gracefully.

**`message`** - a CBOR-encoded byte buffer. Pattern matching uses
`extract`/`match` with a composable matcher DSL (`string`, `array`, `any`,
`more`, etc.).

**`hub`** - a pub/sub broadcast actor. Subscribers receive all broadcasts;
supports filtering and Unix socket-based IPC.

---

## I/O Primitives

| Primitive                        | Purpose                                          |
| -------------------------------- | ------------------------------------------------ |
| `timeout`                        | One-shot timer                                   |
| `metronome`                      | Repeating timer                                  |
| `signal`                         | OS signal handling                               |
| `tcp_acceptor` / `tcp_connector` | TCP networking                                   |
| `unx_acceptor` / `unx_connector` | Unix domain sockets                              |
| `socket`                         | Raw FD-backed socket I/O                         |
| `file_descriptor`                | Async wait on arbitrary file descriptors (posix) |
| `file_stream`                    | Async read/write on file handles (win32)         |
| `subprocess`                     | Child process management (platform-specific)     |

### ⚠️ I/O Primitive Ownership - Critical Rule

**Every I/O primitive is owned by the actor that was executing at the time
it was created.** Async completion messages from a primitive are delivered
only to that owning actor. There is no way to transfer ownership or
redirect delivery to a different actor after construction.

A common mistake is to create an I/O primitive in one actor and then spawn
a separate "handler" actor, passing the primitive (or its handle) to it.
The handler will never receive any events - they will continue to be
delivered to the original actor that created the primitive.

**The correct pattern:** the actor responsible for handling a primitive's
events must be the one that creates it. If you need a dedicated handler
actor, have it create its own primitives from within its own behaviour.

---

## Ownership & Lifecycle

- Zig's `pid` is `Owned` (must call `deinit()`); `pid_ref` is `Wrapped`
  (borrowed, no deinit required)
- Actors can `trap()` exit signals and `link()` to other actors for supervision
- `spawn_link` ties an actor's lifetime to its parent

---

## Build System

- **Zig 0.15.2+** required
- Dependencies: `cbor` (CBOR codec), `asio` (ASIO network executor),
  `tracy` (optional profiling via `-Denable_tracy=true`)
- Produces a static library `libthespian` and a Zig module
- Tests live in `test/` and cover both the C++ and Zig APIs

---

## Misc

See DeepWiki for more documentation: [![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/neurocyte/thespian)
