"""Core call wrappers and public factories.

Every task/trace/run call goes through a small generic wrapper that
records begin/end events in the shared state module, then invokes the
bound function. The function is a compile-time value (a ``thin``
function type), so there are no runtime closures and no decorators:

    comptime double = flyte.trace[f=_double, name="double"]()
    comptime summarize = env.task[f=_summarize, name="summarize"]()
    var run = flyte.run[f=summarize, name="summarize"]("hello")
"""
from ._run import Run
from ._state import state

# ---------------------------------------------------------------------------
# Trace wrappers
# ---------------------------------------------------------------------------


def _trace0[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, fqn: String]() raises -> B:
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


def _task0[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, fqn: String]() raises -> B:
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


def _task1[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, fqn: String](x: A) raises -> B:
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


def _task2[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, fqn: String](x: A, y: C) raises -> B:
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


def _task3[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, fqn: String](x: A, y: C, z: D) raises -> B:
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
# manages the run lifecycle.
# ---------------------------------------------------------------------------


def _run0[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, fqn: String, run_name: String]() raises -> Run[B]:
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


def _run1[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, fqn: String, run_name: String](x: A) raises -> Run[B]:
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


def _run2[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, fqn: String, run_name: String](x: A, y: C) raises -> Run[B]:
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


def _run3[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, fqn: String, run_name: String](x: A, y: C, z: D) raises -> Run[B]:
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


def task[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, name: String]() -> def() raises thin -> B:
    return _task0[f=f, fqn=name]


def task[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, name: String]() -> def(x: A) raises thin -> B:
    return _task1[f=f, fqn=name]


def task[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, name: String]() -> def(x: A, y: C) raises thin -> B:
    return _task2[f=f, fqn=name]


def task[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, name: String]() -> def(x: A, y: C, z: D) raises thin -> B:
    return _task3[f=f, fqn=name]


def run[B: Writable & Copyable & Deinitable, f: def() raises thin -> B, name: String, run_name: String = ""]() raises -> Run[B]:
    return _run0[f=f, fqn=name, run_name=run_name]()


def run[A: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A) raises thin -> B, name: String, run_name: String = ""](x: A) raises -> Run[B]:
    return _run1[f=f, fqn=name, run_name=run_name](x)


def run[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C) raises thin -> B, name: String, run_name: String = ""](x: A, y: C) raises -> Run[B]:
    return _run2[f=f, fqn=name, run_name=run_name](x, y)


def run[A: Writable & Copyable & Deinitable, C: Writable & Copyable & Deinitable, D: Writable & Copyable & Deinitable, B: Writable & Copyable & Deinitable, f: def(A, C, D) raises thin -> B, name: String, run_name: String = ""](x: A, y: C, z: D) raises -> Run[B]:
    return _run3[f=f, fqn=name, run_name=run_name](x, y, z)
