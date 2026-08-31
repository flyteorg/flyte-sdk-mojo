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

# Reuse cannot be combined with resources or secrets, so it is checked alone.
REUSE_SPEC = "reuse_replicas=2\treuse_idle_ttl=60\treuse_scope=run"

env = flyte.TaskEnvironment(name="probe")


@env.task
async def probe(x: str) -> str:
    return x


def _shim_source(image):
    """Render the generated action shim, the way the driver does."""
    import _flyte_mojo_state as st

    return st._SHIM % {
        "action": "e.a", "program": "p.mojo", "binary": st.BINARY_NAME,
        "runtime": st.SHIM_RUNTIME, "libs": [], "env_name": "e", "tasks": "",
        "image": (", image=%r" % image) if image else "",
    }


def main():
    failures = []
    passed = []

    def check(label, ok, detail=""):
        print(("  PASS " if ok else "  FAIL ") + label + ("" if ok else "  -> %s" % detail))
        (passed if ok else failures).append(label)

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

    def refused(label, spec, needle="flyte:"):
        """The SDK's own error, raised before an action exists to fail."""
        try:
            shim.override_kwargs(spec)
            check(label, False, "no error raised")
        except ValueError as exc:
            check(label, needle in str(exc), exc)

    # A fixed count is one number; a pool that scales is two. Flyte spells the
    # second a (min, max) tuple, and the encoder keeps them apart.
    scaled = shim.configured(probe, "reuse_replicas=1\treuse_max_replicas=3").reusable
    check("a replica range reaches the template as (min, max)", scaled.replicas == (1, 3), scaled)
    check("a policy leaves Flyte's other defaults alone",
          scaled.concurrency == 1 and scaled.scope == "global", scaled)
    check("scaledown_ttl reaches the policy",
          shim.configured(probe, "reuse_replicas=2\treuse_scaledown_ttl=120").reusable
          .scaledown_ttl.total_seconds()
          == 120)
    check("concurrency reaches the policy",
          shim.configured(probe, "reuse_replicas=2\treuse_concurrency=4").reusable.concurrency
          == 4)

    # off is the escape hatch: an environment's policy is encoded ahead of the
    # call site that turns it off, and a later policy re-arms the pool.
    escaped = "reuse_replicas=2\treuse_off=true"
    check("reuse_off takes the action out of the pool",
          shim.configured(probe, escaped) is probe and "reusable" not in shim.override_kwargs(escaped))
    check("a policy after reuse_off re-arms it",
          shim.override_kwargs("reuse_off=true\t" + REUSE_SPEC).get("reusable") is not None)

    # Flyte refuses these three combinations from inside override(); the SDK
    # says so in its own terms, naming both settings and the way out.
    refused("combining resources and reuse is refused", "cpu=2\t" + REUSE_SPEC, "cannot combine")
    refused("combining secrets and reuse is refused",
            "secrets=OPENAI_API_KEY\t" + REUSE_SPEC, "cannot combine")
    check("turning reuse off keeps the secrets",
          "secrets" in shim.override_kwargs("secrets=OPENAI_API_KEY\t" + escaped))

    # Flyte checks these when it builds the policy, which for a child action is
    # inside its parent's pod. The values are wrong long before that.
    refused("an idle ttl below the minimum is refused", "reuse_replicas=2\treuse_idle_ttl=10")
    refused("a scaledown ttl below the minimum is refused", "reuse_replicas=2\treuse_scaledown_ttl=5")
    refused("an unknown scope is refused", "reuse_replicas=2\treuse_scope=local")
    refused("a ceiling below the floor is refused",
            "reuse_replicas=4\treuse_max_replicas=2")
    refused("a ceiling with no floor is refused", "reuse_max_replicas=3")
    # Fields layer by last write, like the rest of the spec: a call site that
    # raises the floor of an environment's (1, 3) keeps the environment's top.
    check("a raised floor keeps the environment's ceiling",
          shim.override_kwargs(
              "reuse_replicas=1\treuse_max_replicas=3\treuse_replicas=2"
          )["reusable"].replicas
          == (2, 3))
    refused("a zero concurrency is refused", "reuse_replicas=2\treuse_concurrency=0")
    refused("a zero replica count is refused", "reuse_replicas=0")

    # One container is legal — a single warm worker for a leaf task — but it is
    # the exact shape that deadlocks a parent waiting on its children, and every
    # action of a program shares one pool. So it is allowed, with a warning.
    import contextlib, io

    noise = io.StringIO()
    with contextlib.redirect_stderr(noise):
        solo = shim.configured(probe, "reuse_replicas=1\treuse_concurrency=1")
    check("a single-replica pool is allowed but warned about",
          solo.reusable.replicas == (1, 1) and "Reuse(off=True)" in noise.getvalue(), noise.getvalue())

    # The image is the one setting that cannot ride with the action: Flyte
    # resolves it when the environment is built, so it is baked into the shim.
    check("no image pin leaves Flyte to choose",
          "image=" not in _shim_source(""))
    check("a pinned image reaches the generated environment",
          "image='ghcr.io/x:1'" in _shim_source("ghcr.io/x:1"))
    check("the image is not sent as an override",
          "image" not in shim.override_kwargs("image=ghcr.io/x:1"))

    print()
    print("%d passed, %d failed" % (len(passed), len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
