"""Inspect — looking at work the cluster has already done.

Every other example gives the cluster something to run. This one asks it
questions: what ran recently, how did it go, and what did the last failure
say. That is the control plane, and it is the same API whether the runs came
from Mojo, from Python, or from someone else entirely.

    mojo run -I . examples/inspect.mojo
    RUN=uhmtl75qg9dqnfg2tkfq mojo run -I . examples/inspect.mojo   # one run's logs
"""
from std.os import getenv

from flyte import *


def main() raises:
    var cfg = init_from_config()
    if cfg.mode == MODE_LOCAL:
        print("no cluster configured — nothing to inspect")
        return

    var wanted = String(getenv("RUN", ""))
    if wanted != "":
        var one = status(wanted)
        print(one.name, one.phase)
        print(one.url)
        print()
        print(logs(wanted, lines=30))
        return

    print("recent runs")
    var recent = runs(limit=10)
    var failed = String("")
    for r in recent:
        print("  " + r.phase + "  " + r.name)
        if failed == "" and r.phase == "FAILED":
            failed = r.name

    if failed == "":
        print()
        print("no recent failures")
        return

    print()
    print("last failure: " + failed)
    try:
        print(logs(failed, lines=20))
    except e:
        print("  (no logs available: " + String(e) + ")")
