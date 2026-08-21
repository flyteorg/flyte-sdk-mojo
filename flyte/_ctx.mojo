"""Run context: inspect the current run/action from inside a task or trace."""
from ._state import state


@fieldwise_init
struct Ctx(ImplicitlyCopyable, Writable):
    var run: String
    var action: String
    var depth: Int
    var phase: String
    var mode: String


def ctx() raises -> Ctx:
    """Return the context of the current run (empty strings if none)."""
    var st = state()
    var info = st.ctx_info()
    var depth: Int = Int(String(info["depth"]))
    return Ctx(String(info["run"]), String(info["action"]), depth, String(info["phase"]), String(info["mode"]))
