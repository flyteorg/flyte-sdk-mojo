"""Remote (live cluster) runs.

v1 strategy (design doc, Tier 2): the Mojo SDK drives the Python ``flyte``
control plane — it initializes the cluster session (PKCE auth handled by
the Python SDK), loads the task from a Python file, launches the run on
the cluster, waits for it, and hands back the run name, URL, and output.

    var args: List[String] = ["flyte2"]
    var run = remote_run(file="remote_hello_task.py", task="hello", args=args)
    print(run.name)
    print(run.url)
    print(run.output)
"""
from std.collections import List
from std.python import Python

from ._run import Run
from ._state import state


def remote_run(file: String, task: String, args: List[String]) raises -> Run[String]:
    """Run a task (defined in a Python file) on the live Flyte cluster.

    ``file``  — path to the Python file defining the task.
    ``task``  — the task's name in that file.
    ``args``  — positional arguments for the task (v1: string arguments).
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
