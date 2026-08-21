"""The ``Run`` result type returned by ``flyte.run(...)``."""
from ._mode import is_worker
from ._state import state


@fieldwise_init
struct Run[R: Copyable & Deinitable & Writable](Writable):
    var name: String
    var url: String
    var phase: String
    var output: Self.R

    def report(self) raises -> String:
        """A readable trace report: every task/trace action of this run.

        Remote runs are recorded too, as the single cluster action the
        driver launched — a trace that ran inside the pod is not visible
        from here.
        """
        if is_worker():
            return String("flyte: no trace report inside an action worker")
        var st = state()
        return String(st.report(self.name))
