"""Resume — a task that survives its own failure.

An action that is retried starts again from the top. A checkpoint is the one
thing it carries across, so work already done is not thrown away.

``_train`` fails once, halfway. Its first attempt dies; its second reads the
checkpoint and finishes the remaining steps.

    mojo run -I . examples/resume.mojo
"""
from flyte import *


def _train(steps: Int) raises -> Int:
    var done = 0
    var resumed = checkpoint_load()
    if resumed != "":
        done = Int(resumed)
        print("resuming from step", done)

    while done < steps:
        done += 1
        checkpoint_save(String(done))
        # Fail once, on the attempt that started from nothing.
        if resumed == "" and done * 2 == steps:
            raise Error("evicted at step " + String(done))

    return done


comptime env = TaskEnvironment["ml", reliability=Reliability(retries=1)]()
comptime train = env.task[f=_train, name="train"]()


def main() raises:
    var cfg = init_from_config()
    print("mode:", cfg.mode)

    if cfg.mode == MODE_LOCAL:
        # A local run has no attempts, so stand in for the retry the cluster
        # would do. The checkpoint survives in the process, which is the point.
        try:
            var first = env.run[f=train, name="ml.train"](10)
            print("steps completed:", first.output)
            return
        except e:
            print("attempt 1 failed:", e)
        var second = env.run[f=train, name="ml.train"](10)
        print("steps completed:", second.output)
        return

    var r = env.run[f=train, name="ml.train"](10)
    print("steps completed:", r.output)
    print("url:", r.url)
