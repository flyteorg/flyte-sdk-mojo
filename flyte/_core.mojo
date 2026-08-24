"""Core call wrappers and public factories.

Every task/trace/run call goes through a small generic wrapper. The bound
function is a compile-time value (a ``thin`` function type), so there are
no runtime closures and no decorators:

    comptime double = flyte.trace[f=_double, name="double"]()
    comptime summarize = env.task[f=_summarize, name="summarize"]()
    var run = flyte.run[f=summarize, name="summarize"]("hello")

What the wrapper does depends on the process role (see ``_mode``):

    local   record begin/end events in the Python state bridge, call the
            function, record the result.
    driver  ``run[...]`` hands off to ``_remote``: compile this program for
            linux/amd64, ship it, wait for the cluster, return the result.
    worker  no bookkeeping and no Python at all. Execution replays until it
            reaches the launched action; from there a nested task call
            becomes a Flyte *child action* and a nested trace becomes a
            *span*, both via the control protocol in ``_bridge``. That is
            what turns one Mojo program into a multi-action workflow.
"""
from std.collections import List
from std.sys import argv, exit

from ._bridge import Memo, call, journal_lookup, protocol_active, span_begin, span_end
from ._config import MODE_REMOTE, mode
from ._mode import OUTPUT_MARK, claim_target, is_worker, target_claimed, worker_action
from ._remote import _remote_dispatch
from ._run import Run
from ._state import state
from ._wire import from_wire, supported_on_wire, to_wire

# ---------------------------------------------------------------------------
# Worker helpers
# ---------------------------------------------------------------------------


def _wire_arg[T: Writable & Copyable & Deinitable](index: Int, replayed: T) raises -> T:
    """The driver's argument for position ``index``, read off ``argv``.

    Falls back to ``replayed`` — the value this program recomputed while
    replaying — for types that cannot be read back from a string.
    """
    comptime if supported_on_wire[T]():
        var a = argv()
        if len(a) > index + 1:
            return from_wire[T](String(a[index + 1]))
    return replayed.copy()


def _emit_value[B: Writable & Copyable & Deinitable](var result: B) raises -> B:
    """Publish an action's result to the shim and end the worker process."""
    print(OUTPUT_MARK + String(result), flush=True)
    exit(0)
    raise Error("flyte: unreachable — exit(0) did not terminate the worker")


def _emit[B: Writable & Copyable & Deinitable](var result: B) raises -> Run[B]:
    """As ``_emit_value``, for the run wrappers."""
    var done = _emit_value[B](result^)
    return Run[B](String(""), String(""), String("SUCCEEDED"), done^)


def _replayed[B: Writable & Copyable & Deinitable](var result: B) -> Run[B]:
    """A Run for a non-target action a worker executed while replaying."""
    return Run[B](String(""), String(""), String("SUCCEEDED"), result^)


def _as_child(fqn: String) -> Bool:
    """Should this task call become a Flyte child action rather than a call?

    Only once we are inside the launched action (before that we are still
    replaying), only when a shim is there to service the request, and never
    for the launched action itself — that would spawn a copy of ourselves.
    """
    return protocol_active() and target_claimed() and fqn != worker_action()


def _spans_on() -> Bool:
    """Traces are reported only from inside the launched action."""
    return protocol_active() and target_claimed()


def _memo[B: Writable & Copyable & Deinitable](fqn: String, wire: List[String]) raises -> Memo:
    """A result the shim already computed for this call while replaying.

    Only consulted before the launched action is reached, and only for types
    that can come back off the wire.
    """
    comptime if supported_on_wire[B]():
        if not target_claimed():
            return journal_lookup(fqn, wire)
    return Memo(False, String(""))


# ---------------------------------------------------------------------------
# Trace wrappers
# ---------------------------------------------------------------------------


def _trace0[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, fqn: String]() raises -> B:
    if is_worker():
        if not _spans_on():
            return f()
        span_begin(fqn, [])
        var sr: B
        try:
            sr = f()
        except e:
            span_end(String(""), String(e))
            raise e
        span_end(String(sr), String(""))
        return sr^
    var st = state()
    st.action_begin("trace", fqn, [])
    var r: B
    try:
        r = f()
    except e:
        st.action_finish(None, String(e))
        raise e
    st.action_finish(String(r), None)
    return r^


def _trace1[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, fqn: String](x: A) raises -> B:
    if is_worker():
        if not _spans_on():
            return f(x)
        span_begin(fqn, [to_wire(x)])
        var sr: B
        try:
            sr = f(x)
        except e:
            span_end(String(""), String(e))
            raise e
        span_end(String(sr), String(""))
        return sr^
    var st = state()
    st.action_begin("trace", fqn, [String(x)])
    var r: B
    try:
        r = f(x)
    except e:
        st.action_finish(None, String(e))
        raise e
    st.action_finish(String(r), None)
    return r^


def _trace2[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, fqn: String](x: A, y: C) raises -> B:
    if is_worker():
        if not _spans_on():
            return f(x, y)
        span_begin(fqn, [to_wire(x), to_wire(y)])
        var sr: B
        try:
            sr = f(x, y)
        except e:
            span_end(String(""), String(e))
            raise e
        span_end(String(sr), String(""))
        return sr^
    var st = state()
    st.action_begin("trace", fqn, [String(x), String(y)])
    var r: B
    try:
        r = f(x, y)
    except e:
        st.action_finish(None, String(e))
        raise e
    st.action_finish(String(r), None)
    return r^


def _trace3[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, fqn: String](x: A, y: C, z: D) raises -> B:
    if is_worker():
        if not _spans_on():
            return f(x, y, z)
        span_begin(fqn, [to_wire(x), to_wire(y), to_wire(z)])
        var sr: B
        try:
            sr = f(x, y, z)
        except e:
            span_end(String(""), String(e))
            raise e
        span_end(String(sr), String(""))
        return sr^
    var st = state()
    st.action_begin("trace", fqn, [String(x), String(y), String(z)])
    var r: B
    try:
        r = f(x, y, z)
    except e:
        st.action_finish(None, String(e))
        raise e
    st.action_finish(String(r), None)
    return r^


# ---------------------------------------------------------------------------
# Task wrappers (identical bookkeeping, kind="task")
# ---------------------------------------------------------------------------


def _task0[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, fqn: String, spec: String]() raises -> B:
    if is_worker():
        if claim_target(fqn):
            # this pod was launched to run exactly this action
            var mine = f()
            return _emit_value[B](mine^)
        var wire: List[String] = []
        if _as_child(fqn):
            return from_wire[B](call(fqn, spec, wire))
        var memo = _memo[B](fqn, wire)
        if memo.found:
            return from_wire[B](memo.value)
        return f()
    var st = state()
    st.action_begin("task", fqn, [])
    var r: B
    try:
        r = f()
    except e:
        st.action_finish(None, String(e))
        raise e
    st.action_finish(String(r), None)
    return r^


def _task1[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, fqn: String, spec: String](x: A) raises -> B:
    if is_worker():
        if claim_target(fqn):
            # this pod was launched to run exactly this action
            var mine = f(_wire_arg[A](0, x))
            return _emit_value[B](mine^)
        var wire: List[String] = [to_wire(x)]
        if _as_child(fqn):
            return from_wire[B](call(fqn, spec, wire))
        var memo = _memo[B](fqn, wire)
        if memo.found:
            return from_wire[B](memo.value)
        return f(x)
    var st = state()
    st.action_begin("task", fqn, [String(x)])
    var r: B
    try:
        r = f(x)
    except e:
        st.action_finish(None, String(e))
        raise e
    st.action_finish(String(r), None)
    return r^


def _task2[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, fqn: String, spec: String](x: A, y: C) raises -> B:
    if is_worker():
        if claim_target(fqn):
            # this pod was launched to run exactly this action
            var mine = f(_wire_arg[A](0, x), _wire_arg[C](1, y))
            return _emit_value[B](mine^)
        var wire: List[String] = [to_wire(x), to_wire(y)]
        if _as_child(fqn):
            return from_wire[B](call(fqn, spec, wire))
        var memo = _memo[B](fqn, wire)
        if memo.found:
            return from_wire[B](memo.value)
        return f(x, y)
    var st = state()
    st.action_begin("task", fqn, [String(x), String(y)])
    var r: B
    try:
        r = f(x, y)
    except e:
        st.action_finish(None, String(e))
        raise e
    st.action_finish(String(r), None)
    return r^


def _task3[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, fqn: String, spec: String](x: A, y: C, z: D) raises -> B:
    if is_worker():
        if claim_target(fqn):
            # this pod was launched to run exactly this action
            var mine = f(_wire_arg[A](0, x), _wire_arg[C](1, y), _wire_arg[D](2, z))
            return _emit_value[B](mine^)
        var wire: List[String] = [to_wire(x), to_wire(y), to_wire(z)]
        if _as_child(fqn):
            return from_wire[B](call(fqn, spec, wire))
        var memo = _memo[B](fqn, wire)
        if memo.found:
            return from_wire[B](memo.value)
        return f(x, y, z)
    var st = state()
    st.action_begin("task", fqn, [String(x), String(y), String(z)])
    var r: B
    try:
        r = f(x, y, z)
    except e:
        st.action_finish(None, String(e))
        raise e
    st.action_finish(String(r), None)
    return r^


# ---------------------------------------------------------------------------
# Run wrappers: start a run, execute the (bound) task, finish the run.
# The bound task records its own action event; the run wrapper only
# manages the run lifecycle — or dispatches to the cluster.
# ---------------------------------------------------------------------------


def _run0[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, fqn: String, run_name: String, spec: String]() raises -> Run[B]:
    if is_worker():
        if claim_target(fqn):
            var r = f()
            return _emit[B](r^)
        # not our action: replay so control flow reaching it sees real values
        var replay = f()
        return _replayed[B](replay^)

    if mode() == MODE_REMOTE:
        var wire: List[String] = []
        return _remote_dispatch[B](fqn, run_name, spec, wire)

    var st = state()
    var name = String(st.run_begin(run_name, fqn, "local", ""))
    var r: B
    try:
        r = f()
    except e:
        st.run_finish(None, String(e))
        raise e
    st.run_finish(String(r), None)
    var url = String(st.run_get(name)["url"])
    return Run[B](name, url, "SUCCEEDED", r^)


def _run1[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, fqn: String, run_name: String, spec: String](x: A) raises -> Run[B]:
    if is_worker():
        if claim_target(fqn):
            var r = f(_wire_arg[A](0, x))
            return _emit[B](r^)
        # not our action: replay so control flow reaching it sees real values
        var replay = f(x)
        return _replayed[B](replay^)

    if mode() == MODE_REMOTE:
        var wire: List[String] = [to_wire(x)]
        return _remote_dispatch[B](fqn, run_name, spec, wire)

    var st = state()
    var name = String(st.run_begin(run_name, fqn, "local", ""))
    var r: B
    try:
        r = f(x)
    except e:
        st.run_finish(None, String(e))
        raise e
    st.run_finish(String(r), None)
    var url = String(st.run_get(name)["url"])
    return Run[B](name, url, "SUCCEEDED", r^)


def _run2[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, fqn: String, run_name: String, spec: String](x: A, y: C) raises -> Run[B]:
    if is_worker():
        if claim_target(fqn):
            var r = f(_wire_arg[A](0, x), _wire_arg[C](1, y))
            return _emit[B](r^)
        # not our action: replay so control flow reaching it sees real values
        var replay = f(x, y)
        return _replayed[B](replay^)

    if mode() == MODE_REMOTE:
        var wire: List[String] = [to_wire(x), to_wire(y)]
        return _remote_dispatch[B](fqn, run_name, spec, wire)

    var st = state()
    var name = String(st.run_begin(run_name, fqn, "local", ""))
    var r: B
    try:
        r = f(x, y)
    except e:
        st.run_finish(None, String(e))
        raise e
    st.run_finish(String(r), None)
    var url = String(st.run_get(name)["url"])
    return Run[B](name, url, "SUCCEEDED", r^)


def _run3[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, fqn: String, run_name: String, spec: String](x: A, y: C, z: D) raises -> Run[B]:
    if is_worker():
        if claim_target(fqn):
            var r = f(_wire_arg[A](0, x), _wire_arg[C](1, y), _wire_arg[D](2, z))
            return _emit[B](r^)
        # not our action: replay so control flow reaching it sees real values
        var replay = f(x, y, z)
        return _replayed[B](replay^)

    if mode() == MODE_REMOTE:
        var wire: List[String] = [to_wire(x), to_wire(y), to_wire(z)]
        return _remote_dispatch[B](fqn, run_name, spec, wire)

    var st = state()
    var name = String(st.run_begin(run_name, fqn, "local", ""))
    var r: B
    try:
        r = f(x, y, z)
    except e:
        st.run_finish(None, String(e))
        raise e
    st.run_finish(String(r), None)
    var url = String(st.run_get(name)["url"])
    return Run[B](name, url, "SUCCEEDED", r^)


# ---------------------------------------------------------------------------
# Public factories: trace / task / run
# ---------------------------------------------------------------------------


def trace[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, name: String]() -> def() raises thin -> B:
    return _trace0[f=f, fqn=name]


def trace[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, name: String]() -> def(x: A) raises thin -> B:
    return _trace1[f=f, fqn=name]


def trace[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, name: String]() -> def(x: A, y: C) raises thin -> B:
    return _trace2[f=f, fqn=name]


def trace[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, name: String]() -> def(x: A, y: C, z: D) raises thin -> B:
    return _trace3[f=f, fqn=name]


def task[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, name: String, spec: String = ""]() -> def() raises thin -> B:
    return _task0[f=f, fqn=name, spec=spec]


def task[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, name: String, spec: String = ""]() -> def(x: A) raises thin -> B:
    return _task1[f=f, fqn=name, spec=spec]


def task[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, name: String, spec: String = ""]() -> def(x: A, y: C) raises thin -> B:
    return _task2[f=f, fqn=name, spec=spec]


def task[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, name: String, spec: String = ""]() -> def(x: A, y: C, z: D) raises thin -> B:
    return _task3[f=f, fqn=name, spec=spec]


def run[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, name: String, run_name: String = "", spec: String = ""]() raises -> Run[B]:
    return _run0[f=f, fqn=name, run_name=run_name, spec=spec]()


def run[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, name: String, run_name: String = "", spec: String = ""](x: A) raises -> Run[B]:
    return _run1[f=f, fqn=name, run_name=run_name, spec=spec](x)


def run[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, name: String, run_name: String = "", spec: String = ""](x: A, y: C) raises -> Run[B]:
    return _run2[f=f, fqn=name, run_name=run_name, spec=spec](x, y)


def run[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, name: String, run_name: String = "", spec: String = ""](x: A, y: C, z: D) raises -> Run[B]:
    return _run3[f=f, fqn=name, run_name=run_name, spec=spec](x, y, z)
