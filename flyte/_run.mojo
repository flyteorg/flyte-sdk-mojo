"""The ``Run`` result type returned by ``flyte.run(...)``."""
from ._state import state


@fieldwise_init
struct Run[R: Copyable & Deinitable & Writable](Writable):
    var name: String
    var url: String
    var phase: String
    var output: Self.R

    def report(self) raises -> String:
        """A readable trace report: every task/trace action of this run."""
        var st = state()
        return String(st.report(self.name))
