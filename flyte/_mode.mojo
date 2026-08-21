"""Execution-mode detection — pure Mojo, no Python bridge.

A program written against this SDK plays one of three roles, and the same
source file is used for all of them:

    local   `mojo run prog.mojo` with no cluster config — tasks execute
            in-process and the run is recorded in the local trace.
    driver  `mojo run prog.mojo` after ``init_from_config()`` found a
            cluster endpoint — ``run[...]`` compiles the program for
            linux/amd64, ships it, and waits for the cluster.
    worker  the *same program*, compiled, running inside a Flyte action
            pod. ``FLYTE_MOJO_ACTION`` names the action it should execute.

Worker detection deliberately avoids the Python bridge: the action pod
executes a bare native binary and must never need ``_flyte_mojo_state``
(or a Python interpreter) to decide what to do.
"""
from std.os import getenv, setenv

# Set by the action shim in the pod; its value is the action FQN to run.
comptime ACTION_ENV: String = "FLYTE_MOJO_ACTION"

# Prefix marking the one stdout line that carries the action's result.
# Everything else the program prints stays plain stdout (pod logs).
comptime OUTPUT_MARK: String = "__FLYTE_MOJO_OUTPUT__:"

# Process-local: set once the wrapper that owns the launched action starts.
# Mojo has no globals, but a worker owns its own environment.
comptime ENTERED_ENV: String = "FLYTE_MOJO_ENTERED"


def worker_action() -> String:
    """The action this process must execute, or "" when not a worker."""
    return getenv(ACTION_ENV, "")


def is_worker() -> Bool:
    """True when running as a compiled action worker inside a Flyte pod."""
    return worker_action() != ""


def claim_target(fqn: String) -> Bool:
    """True for the one wrapper that owns the action this worker was launched for.

    Everything before it is replay; everything inside it is the real action.
    """
    if fqn != worker_action():
        return False
    if getenv(ENTERED_ENV, "") != "":
        return False
    _ = setenv(ENTERED_ENV, fqn)
    return True


def target_claimed() -> Bool:
    """True once execution has entered the launched action."""
    return getenv(ENTERED_ENV, "") != ""
