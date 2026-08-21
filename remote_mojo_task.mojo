"""Remote Mojo task — run *compiled-Mojo* task bodies on the live cluster.

The task bodies (hello_task.mojo, fib_task.mojo) are compiled to native
linux/amd64 binaries (see `make remote-build`), bundled with the code,
and executed inside the Flyte 2 action by the thin Python shim
(mojo_tasks/hello_remote.py). The Python layer in the pod is only the
subprocess bridge; the computation itself runs as native Mojo code.

Prereqs:
    make remote-build        # docker build of the linux binaries
    ~/.flyte/config.yaml     # cluster config (flyte init)

Run:
    mojo run remote_mojo_task.mojo
"""
from std.collections import List

from flyte import *


def main() raises:
    var cfg = init_from_config()
    print("cluster:", cfg.endpoint, cfg.org, cfg.project, cfg.domain)

    # -- hello: string in, string out ------------------------------------
    var args: List[String] = ["flyte2"]
    var r1 = remote_run(file="mojo_tasks/hello_remote.py", task="hello", args=args)
    print("run:", r1.name)
    print("url:", r1.url)
    print("hello output:", r1.output)

    # -- fib: int in, int out (native-speed compute on the cluster) ------
    var args2: List[String] = ["90"]
    var r2 = remote_run(file="mojo_tasks/hello_remote.py", task="fib", args=args2)
    print("run:", r2.name)
    print("fib(90) =", r2.output)
