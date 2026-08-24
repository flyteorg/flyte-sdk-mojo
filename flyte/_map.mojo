"""Parallel fan-out over a bound task.

    comptime score = env.task[f=_score, name="demo.score"]()

    def _rank(n: Int) raises -> String:
        var scores = map[f=score, name="demo.score"](candidates)
        ...

Inside a task on a cluster this becomes one Flyte child action per item,
all launched together — the pods run in parallel and the caller blocks
until the last one lands. Locally, and while a worker is still replaying,
it is an ordinary loop.
"""
from std.collections import List

from ._bridge import map_call, protocol_active
from ._config import MODE_REMOTE, mode
from ._mode import is_worker, target_claimed, worker_action
from ._wire import from_wire, to_wire


def map[
    A: Writable & Copyable & Deinitable,
    B: Writable & Copyable & Deinitable,
    f: def(A) raises thin -> B,
    name: String,
    spec: String = "",
](items: List[A]) raises -> List[B]:
    """Apply the bound task ``f`` to every item, in parallel when remote."""
    if is_worker():
        if protocol_active() and target_claimed() and name != worker_action():
            var wire = List[String]()
            for item in items:
                wire.append(to_wire(item))
            var raw = map_call(name, spec, wire)
            var out = List[B]()
            for value in raw:
                out.append(from_wire[B](value))
            return out^
    elif mode() == MODE_REMOTE:
        raise Error(
            "flyte: map[f=..., name='"
            + name
            + "'] fans out from inside a task. Call it in a task body and run"
            " that task, rather than at the top level of main()."
        )

    var out = List[B]()
    for item in items:
        out.append(f(item))
    return out^
