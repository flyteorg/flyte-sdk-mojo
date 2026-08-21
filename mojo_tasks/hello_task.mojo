"""Hello task — the compiled-Mojo task body for remote execution.

Protocol: argv[1] = name; stdout = result; non-zero exit = failure.
This program is compiled to a native binary (linux/amd64 for the cluster)
and executed inside the Flyte 2 action by the Python shim, so the task
body itself runs as native Mojo code on the cluster.
"""
from std.sys import argv


def main() raises:
    var args = argv()
    if len(args) < 2:
        raise Error("usage: hello <name>")
    var name: String = args[1]
    if name == "":
        raise Error("name must not be empty")
    print("hello, " + name + "! (compiled Mojo, running on the cluster)")
