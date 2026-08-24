"""Remote (live cluster) runs.

Two entry points, in order of how much you have to think about:

``_remote_dispatch`` — what ``run[...]`` uses in remote mode. It ships *this
program*: the Python bridge compiles the running .mojo source to a
linux/amd64 binary, bundles it with a generated action shim, launches the
run, waits, and hands back the result. Nothing extra to write.

``remote_run(file, task, args)`` — the explicit escape hatch: launch a task
that is defined in a Python file. Use it to call into Python tasks that
already exist; the Mojo side is only the control plane.
"""
from std.collections import List
from std.python import Python

from ._run import Run
from ._state import state
from ._wire import from_wire


def _remote_dispatch[B: Writable & Copyable & Deinitable](
    fqn: String, run_name: String, spec: String, args: List[String]
) raises -> Run[B]:
    """Run action ``fqn`` of the running program on the cluster."""
    var st = state()
    var py_args = Python.list()
    for a in args:
        py_args.append(a)
    var result = st.remote_run_mojo(fqn, py_args, run_name, spec)
    var out = from_wire[B](String(result["output"]))
    return Run[B](
        String(result["name"]), String(result["url"]), String(result["phase"]), out^
    )


def remote_run(file: String, task: String, args: List[String]) raises -> Run[String]:
    """Run a task defined in a *Python* file on the live Flyte cluster.

    ``file``  — path to the Python file defining the task.
    ``task``  — the task's name in that file.
    ``args``  — positional arguments for the task (string arguments).
    """
    var st = state()
    var py_args = Python.list()
    for a in args:
        py_args.append(a)
    var result = st.remote_run(file, task, py_args)
    var url = String(result["url"])
    var run_name = String(result["name"])
    var output = String(result["output"])
    return Run[String](run_name, url, "SUCCEEDED", output)
