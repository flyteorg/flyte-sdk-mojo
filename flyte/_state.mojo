"""Bridge to the shared Python state module.

Mojo has no module-level mutable state, so all SDK state (runs, trace
events, config) lives in a Python module (``_flyte_mojo_state.py``) that
is imported on first use and cached in the interpreter's module registry.
The bridge keeps the boundary flat: only strings, numbers, booleans, and
lists of those cross over.
"""
from std.python import Python, PythonObject


def state() raises -> PythonObject:
    """Return the shared state module, importing it on first use."""
    try:
        return Python.import_module("_flyte_mojo_state")
    except e:
        raise Error(
            "flyte: cannot import the '_flyte_mojo_state' module. "
            "Make sure _flyte_mojo_state.py is next to your main file "
            "(or on PYTHONPATH)."
        )
