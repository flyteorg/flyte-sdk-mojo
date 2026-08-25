"""Checkpoints: state that survives an attempt.

A task that is retried, or evicted off preemptible capacity, starts again
from the top. A checkpoint is the one thing it can carry across:

    def _train(steps: Int) raises -> Int:
        var done = 0
        var resumed = checkpoint_load()
        if resumed != "":
            done = Int(resumed)
        while done < steps:
            done += 1
            checkpoint_save(String(done))
        return done

Checkpoints belong to an *attempt of an action*, so they only mean something
where attempts exist. In a worker the shim persists them through Flyte; run
the same program locally and they live for the length of the process, which
is enough to exercise the code path but is not durable.
"""
from ._bridge import checkpoint_load as _wire_load, checkpoint_save as _wire_save, protocol_active
from ._mode import is_worker, target_claimed
from ._state import state


def checkpoint_save(text: String) raises:
    """Persist ``text`` for the next attempt of this action."""
    if is_worker():
        if protocol_active() and target_claimed():
            _wire_save(text)
        return
    _ = state().checkpoint_save(text)


def checkpoint_load() raises -> String:
    """What the previous attempt saved, or "" if there was none."""
    if is_worker():
        if protocol_active() and target_claimed():
            return _wire_load()
        return String("")
    return String(state().checkpoint_load())
