"""Check that a spec becomes a real Flyte task override.

The mapping in ``flyte_mojo_shim`` is only half the story: what matters is
that the result lands on a TaskTemplate, and that overriding does not mutate
the module-level task the shim reuses for every action.
"""

import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "flyte"))

import flyte  # noqa: E402
import flyte_mojo_shim as shim  # noqa: E402

SPEC = "\t".join([
    "cpu=2", "memory=4Gi", "gpu=1", "gpu_type=A100",
    "cache=auto",
    "retries=3", "timeout_runtime=60", "interruptible=true",
    "secrets=OPENAI_API_KEY, DB_PASS=DATABASE_PASSWORD", "secret_group=team",
])

# Reuse cannot be combined with resources, so it is checked on its own.
REUSE_SPEC = "reuse_replicas=2\treuse_idle_ttl=60\treuse_scope=run"

env = flyte.TaskEnvironment(name="probe")


@env.task
async def probe(x: str) -> str:
    return x


def main():
    failures = []

    def check(label, ok, detail=""):
        print(("  PASS " if ok else "  FAIL ") + label + ("" if ok else "  -> %s" % detail))
        if not ok:
            failures.append(label)

    over = shim.configured(probe, SPEC)
    check("resources reach the template", str(getattr(over, "resources", None)).startswith("Resources(cpu='2'"),
          getattr(over, "resources", None))
    check("a typed GPU becomes device:count", "A100:1" in str(getattr(over, "resources", None)),
          getattr(over, "resources", None))
    check("cache reaches the template", getattr(over, "cache", None) is not None)
    check("retries reach the template", getattr(getattr(over, "retries", None), "count", None) == 3,
          getattr(over, "retries", None))
    check("timeout reaches the template", getattr(over, "timeout", None) is not None)
    check("interruptible reaches the template", getattr(over, "interruptible", None) is True,
          getattr(over, "interruptible", None))
    secrets = getattr(over, "secrets", None) or []
    check("both secrets reach the template", len(secrets) == 2, secrets)
    check("a renamed secret keeps its env var",
          any(getattr(s, "as_env_var", None) == "DATABASE_PASSWORD" for s in secrets), secrets)
    check("a group applies to them", all(getattr(s, "group", None) == "team" for s in secrets), secrets)

    # The shim overrides a module-level task once per dispatch, so overriding
    # has to return a new template rather than mutate the shared one.
    check("the original task is untouched", getattr(probe, "resources", None) is None,
          getattr(probe, "resources", None))
    check("an empty spec returns the task itself", shim.configured(probe, "") is probe)

    warm = shim.configured(probe, REUSE_SPEC)
    reuse = getattr(warm, "reusable", None)
    check("a reuse policy reaches the template", getattr(reuse, "replicas", None) == (2, 2), reuse)
    check("its idle ttl and scope come with it",
          getattr(reuse, "scope", None) == "run" and getattr(reuse, "idle_ttl", None) is not None, reuse)
    check("no reuse policy unless replicas are asked for",
          shim.override_kwargs("reuse_idle_ttl=60").get("reusable") is None)

    try:
        shim.override_kwargs("cpu=2\t" + REUSE_SPEC)
        check("combining resources and reuse is refused", False, "no error raised")
    except ValueError as exc:
        check("combining resources and reuse is refused", "cannot combine" in str(exc), exc)

    print()
    print("%d passed, %d failed" % (15 - len(failures), len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
