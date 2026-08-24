"""The control plane: asking the cluster about work, rather than giving it work.

Everything else in this SDK launches actions. These are the operations you
reach for afterwards — what ran, how did it go, why did it fail, run it again:

    var recent = runs(limit=5)
    for r in recent:
        print(r.name, r.phase)

    print(logs("uhmtl75qg9dqnfg2tkfq", lines=20))
    _ = abort("uzdmh87f86jk26pc8wzt")

These are driver-side only. A worker is *inside* an action and has no business
steering the run it belongs to, so calling one there raises rather than
quietly doing nothing.
"""
from std.collections import List

from std.python import PythonObject

from ._mode import is_worker
from ._state import state


@fieldwise_init
struct RunInfo(ImplicitlyCopyable, Writable):
    """A run as the control plane sees it."""

    var name: String
    var phase: String
    var url: String


def _driver_only(what: String) raises:
    if is_worker():
        raise Error(
            "flyte: " + what + " is a control-plane call and cannot be made"
            " from inside an action. Call it from the program that launches"
            " the run."
        )


def _row(value: PythonObject) raises -> RunInfo:
    return RunInfo(String(value[0]), String(value[1]), String(value[2]))


def runs(limit: Int = 20) raises -> List[RunInfo]:
    """Recent runs, newest first."""
    _driver_only("runs()")
    var rows = state().cp_runs(limit)
    var out = List[RunInfo]()
    for row in rows:
        out.append(_row(row))
    return out^


def status(name: String) raises -> RunInfo:
    """One run's current state, refreshed from the cluster."""
    _driver_only("status()")
    return _row(state().cp_status(name))


def abort(name: String) raises -> RunInfo:
    """Stop a run and everything under it. Aborting a finished run is a no-op."""
    _driver_only("abort()")
    return _row(state().cp_abort(name))


def logs(name: String, lines: Int = 50) raises -> String:
    """The tail of a run's logs."""
    _driver_only("logs()")
    return String(state().cp_logs(name, lines))


def rerun(name: String) raises -> RunInfo:
    """Run the same task again, with the same inputs."""
    _driver_only("rerun()")
    return _row(state().cp_rerun(name))
