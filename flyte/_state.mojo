"""Bridge to the SDK's Python state module.

Mojo has no module-level mutable state, so all *driver-side* SDK state
(runs, trace events, config, the remote build) lives in a Python module
that ships inside this package as ``flyte/_flyte_mojo_state.py``. The
bridge keeps the boundary flat: only strings, numbers, booleans, and lists
of those cross over.

The package directory deliberately has no ``__init__.py``: adding one would
turn ``flyte/`` into a regular Python package on ``sys.path`` and shadow the
installed Flyte SDK. So the bridge is found by path and imported under its
own name, never as ``flyte._flyte_mojo_state``.

Nothing on the *worker* path calls this. A task pod runs a bare native
binary, and asking it for a Python interpreter would be a needless
dependency — see ``_mode``.
"""
from std.collections import List
from std.os import getenv
from std.sys import argv
from std.python import Python, PythonObject

comptime _MODULE: String = "_flyte_mojo_state"

# Point this at the SDK's `flyte/` directory if it does not sit beside the
# program (a vendored copy, say). Rarely needed.
comptime _SDK_ENV: String = "FLYTE_MOJO_SDK"


def _package_dir() raises -> String:
    """Locate the ``flyte/`` package directory holding the Python bridge."""
    var os = Python.import_module("os")

    var override = getenv(_SDK_ENV, "")
    if override != "":
        return override

    # The package normally sits beside the program being run, but a program
    # in a subdirectory should still find it, so walk up from both the
    # program and the working directory.
    var starts = List[String]()
    var a = argv()
    if len(a) > 0:
        starts.append(String(os.path.dirname(os.path.abspath(String(a[0])))))
    starts.append(String(os.getcwd()))

    for start in starts:
        var here = String(start)
        for _ in range(8):
            var candidate = String(os.path.join(here, "flyte"))
            if Bool(os.path.exists(os.path.join(candidate, _MODULE + ".py"))):
                return candidate
            var parent = String(os.path.dirname(here))
            if parent == here:
                break
            here = parent
    return String("")


def state() raises -> PythonObject:
    """Return the shared state module, importing it on first use."""
    # Cheap on every call after the first: Python caches it in sys.modules.
    try:
        return Python.import_module(_MODULE)
    except:
        pass

    var package = _package_dir()
    if package == "":
        raise Error(
            "flyte: cannot find the SDK's Python bridge (flyte/"
            + _MODULE
            + ".py). Run your program from a directory that has the flyte/"
            " package beside it, or set "
            + _SDK_ENV
            + " to the package directory."
        )

    var sys = Python.import_module("sys")
    if package not in sys.path:
        sys.path.insert(0, package)
    try:
        return Python.import_module(_MODULE)
    except e:
        raise Error(
            "flyte: found the Python bridge at " + package + " but could not"
            " import it (" + String(e) + ")."
        )
