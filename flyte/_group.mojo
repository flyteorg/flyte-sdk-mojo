"""Grouping — name a region of a workflow.

A group is a label on a *region* of your program, not on a single call, so
it maps onto Mojo's `with` statement:

    with group("scoring"):
        var scores = map[f=score, name="etl.score"](items)
        var total = combine(scores)

Everything launched inside the block lands under that name in the Flyte UI.
Groups nest, and the block is left cleanly even if something inside it
raises. Locally the same block shows up as a level in the run report.

Grouping is entirely opt-in: without it, actions sit directly under their
caller, which is usually what you want.
"""
from ._bridge import group_begin as _wire_group_begin, group_end as _wire_group_end, protocol_active
from ._mode import is_worker, target_claimed
from ._state import state


struct Group(Movable):
    """The scope opened by ``group(name)``. Use it with `with`."""

    var name: String
    var opened: Bool
    """Whether entering actually opened a group — so leaving can mirror it."""

    def __init__(out self, name: String):
        self.name = name
        self.opened = False

    def __enter__(mut self):
        # Mojo's `with` protocol wants both ends non-raising, and grouping is
        # bookkeeping: if it cannot be recorded the workflow should still run.
        # A bridge that is genuinely broken will say so on the next task call.
        try:
            if is_worker():
                # While replaying towards the launched action there is nothing
                # to group — those calls are not happening on the cluster.
                if protocol_active() and target_claimed():
                    _wire_group_begin(self.name)
                    self.opened = True
            else:
                state().group_begin(self.name)
                self.opened = True
        except:
            self.opened = False

    def __exit__(mut self):
        # Leaving a group must not raise: this runs while an error from the
        # body may already be propagating, and losing that error to a
        # bookkeeping failure would be much worse than an unclosed group.
        if not self.opened:
            return
        self.opened = False
        try:
            if is_worker():
                _wire_group_end()
            else:
                state().group_end()
        except:
            pass


def group(name: String) -> Group:
    """Open a named group for the duration of a `with` block."""
    return Group(name)
