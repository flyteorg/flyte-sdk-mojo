"""Remote hello — run a task on the live Flyte cluster from Mojo.

Auth: the Python flyte SDK handles PKCE (cached session in ~/.flyte).
Cluster: from ~/.flyte/config.yaml (demo.hosted.unionai.cloud).

Run:
    mojo run remote_hello.mojo
"""
from std.collections import List

from flyte import *


def main() raises:
    # load cluster config (endpoint/org/project/domain)
    var cfg = init_from_config()
    print("cluster:", cfg.endpoint, cfg.org, cfg.project, cfg.domain)

    # launch the task on the live cluster and wait for completion
    var args: List[String] = ["flyte2"]
    var run = remote_run(file="remote_hello_task.py", task="hello", args=args)

    print("run name:", run.name)
    print("run url:", run.url)
    print("phase:", run.phase)
    print("output:", run.output)
