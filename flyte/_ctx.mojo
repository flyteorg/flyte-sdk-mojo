"""Run context: inspect the current run/action from inside a task or trace."""
from ._mode import is_worker, worker_action
from ._state import state


@fieldwise_init
struct Ctx(ImplicitlyCopyable, Writable):
    var run: String
    var action: String
    var depth: Int
    var phase: String
    var mode: String


def ctx() raises -> Ctx:
    """Return the context of the current run (empty strings if none).

    Inside an action pod there is no local trace to consult and no Python
    bridge to consult it with, so the worker answers from its own role.
    """
    if is_worker():
        return Ctx(String(""), worker_action(), 1, String("RUNNING"), String("worker"))
    var st = state()
    var info = st.ctx_info()
    var depth: Int = Int(String(info["depth"]))
    return Ctx(String(info["run"]), String(info["action"]), depth, String(info["phase"]), String(info["mode"]))
