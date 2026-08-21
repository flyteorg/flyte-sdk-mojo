"""Shim tasks for compiled-Mojo remote execution.

The *task bodies* are native Mojo binaries (``hello_binary``, ``fib_binary``)
that sit next to this file in the code bundle, together with the small Mojo
runtime libraries they link against (``libKGENCompilerRTShared.so`` and
friends). A Flyte 2 action worker imports a Python task to run, so this
module provides the thinnest possible bridge: each task execs its binary
and returns its stdout.

Failure semantics: binary non-zero exit -> RuntimeError with its stderr.
"""
import os
import subprocess

import flyte

_HERE = os.path.dirname(os.path.abspath(__file__))

# Mojo runtime shared libraries, bundled next to the binaries.
_LIBS = [
    os.path.join(_HERE, "libKGENCompilerRTShared.so"),
    os.path.join(_HERE, "libMSupportGlobals.so"),
    os.path.join(_HERE, "libAsyncRTRuntimeGlobals.so"),
]

env = flyte.TaskEnvironment(
    name="mojo_remote",
    include=[
        os.path.join(_HERE, "hello_binary"),
        os.path.join(_HERE, "fib_binary"),
    ]
    + [p for p in _LIBS if os.path.exists(p)],
)


def _run_mojo_binary(binary: str, *args: str) -> str:
    exe = os.path.join(_HERE, binary)
    if not os.path.exists(exe):
        raise RuntimeError(f"bundled Mojo binary not found: {exe}")
    p = subprocess.run(
        [exe, *args],
        capture_output=True,
        text=True,
        timeout=300,
        env={**os.environ, "LD_LIBRARY_PATH": _HERE},
    )
    if p.returncode != 0:
        detail = (p.stderr.strip() or p.stdout.strip() or "no output")
        # keep the message single-line for the cluster error report
        detail = " | ".join(line for line in detail.splitlines() if line.strip())
        raise RuntimeError(f"mojo task {binary} failed (exit {p.returncode}): {detail}")
    return p.stdout.rstrip("\n")


@env.task
def hello(name: str) -> str:
    """Greet `name` — executed by the compiled-Mojo hello binary."""
    return _run_mojo_binary("hello_binary", name)


@env.task
def fib(n: str) -> str:
    """Compute fib(n) — executed by the compiled-Mojo fib binary.

    ``n`` is a decimal string (0..91); the binary validates it and raises
    with a clean error on bad input.
    """
    return _run_mojo_binary("fib_binary", n)
