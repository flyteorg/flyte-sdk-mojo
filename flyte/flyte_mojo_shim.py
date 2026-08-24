"""Pod-side runtime for compiled-Mojo Flyte actions.

Part of the SDK, but the only part that runs *inside the action pod*: it is
copied into the code bundle next to the compiled Mojo binary it drives. The
generated per-action shim is only a few lines — it builds the
TaskEnvironment and calls ``drive`` here.

``drive`` execs the binary with ``FLYTE_MOJO_ACTION`` naming the action to
run and speaks the control protocol in ``flyte/_bridge.mojo`` over pipes, so
the Mojo program can ask for real Flyte work while it runs:

    CALL call fqn spec args -> a child action (a new pod, same binary)
    CALL map  fqn spec args -> one child action per argument, in parallel
    SPAN begin fqn args...  ->  open a flyte.trace context
    SPAN end   output error ->  close it
    GROUP begin name        ->  open a flyte.group context
    GROUP end               ->  close it
    OUTPUT value            ->  the action's result

Because the trace context is held open for exactly as long as the Mojo code
runs, spans carry real timings and nest correctly in the Flyte UI.

A worker launched for a late action still runs main() from the top to reach
it, so every child action is handed a *journal* of the results already
computed for this run. The Mojo side reads it back instead of re-executing
those calls — otherwise a five-step pipeline would run step one five times.
"""

import asyncio
import os
import re
import subprocess
from datetime import timedelta

import flyte

BINARY_NAME = "task_binary"
OUTPUT_MARK = "__FLYTE_MOJO_OUTPUT__:"
CALL_MARK = "__FLYTE_MOJO_CALL__:"
SPAN_MARK = "__FLYTE_MOJO_SPAN__:"
GROUP_MARK = "__FLYTE_MOJO_GROUP__:"

# Lines the Mojo runtime always prints, which say nothing about a failure.
_NOISE = ("stack trace was not collected",)
_PANIC = "Unhandled exception caught during execution: "


class _WorkerExit(Exception):
    """The binary closed its stdout — its exit code explains why."""


# --------------------------------------------------------------------------
# Field codec — mirrors _escape/_unescape in flyte/_bridge.mojo
# --------------------------------------------------------------------------

def _escape(field):
    return (
        field.replace("\\", "\\\\")
        .replace("\t", "\\t")
        .replace("\n", "\\n")
        .replace("\r", "\\r")
    )


def _unescape(field):
    out = []
    pending = False
    for ch in field:
        if pending:
            out.append({"t": "\t", "n": "\n", "r": "\r"}.get(ch, ch))
            pending = False
        elif ch == "\\":
            pending = True
        else:
            out.append(ch)
    return "".join(out)


def _decode_row(payload):
    return [_unescape(f) for f in payload.split("\t")]


def _encode_row(fields):
    return "\t".join(_escape(str(f)) for f in fields)


# --------------------------------------------------------------------------
# Task configuration — the other half of flyte/_spec.mojo
# --------------------------------------------------------------------------

def decode_spec(spec):
    """Parse a task spec into a dict. Later fields win, so a task override
    beats the environment setting it was appended to."""
    conf = {}
    for field in (spec or "").split("\t"):
        if not field:
            continue
        key, _, value = field.partition("=")
        conf[key] = _unescape(value)
    return conf


def _resources(conf):
    cpu, memory, gpu = conf.get("cpu"), conf.get("memory"), conf.get("gpu")
    if not (cpu or memory or gpu):
        return None
    device = None
    if gpu:
        gpu_type = conf.get("gpu_type")
        # Flyte takes a bare count, or "<device>:<count>" when a type is named.
        device = "%s:%s" % (gpu_type, gpu) if gpu_type else int(gpu)
    return flyte.Resources(cpu=cpu, memory=memory, gpu=device)


def _cache(conf):
    behavior = conf.get("cache")
    if not behavior:
        return None
    version, salt = conf.get("cache_version"), conf.get("cache_salt")
    if not (version or salt):
        return behavior  # Flyte takes the bare literal
    return flyte.Cache(behavior=behavior, version_override=version, salt=salt or "")


def _backoff(conf):
    """The pacing between retries, or None for back-to-back attempts."""
    base = conf.get("backoff_base")
    if not base:
        return None
    policy = {"base": timedelta(seconds=int(base))}
    if conf.get("backoff_factor"):
        policy["factor"] = float(conf["backoff_factor"])
    if conf.get("backoff_cap"):
        policy["cap"] = timedelta(seconds=int(conf["backoff_cap"]))
    return flyte.Backoff(**policy)


def _timeout(conf):
    """The wall-clock bounds, or None when none are set."""
    bounds = {}
    if conf.get("timeout_runtime"):
        bounds["max_runtime"] = int(conf["timeout_runtime"])
    if conf.get("timeout_queued"):
        bounds["max_queued_time"] = int(conf["timeout_queued"])
    if conf.get("timeout_deadline"):
        bounds["deadline"] = int(conf["timeout_deadline"])
    return flyte.Timeout(**bounds) if bounds else None


def _reliability(conf, kwargs):
    if conf.get("retries"):
        backoff = _backoff(conf)
        kwargs["retries"] = (
            flyte.RetryStrategy(count=int(conf["retries"]), backoff=backoff)
            if backoff
            else int(conf["retries"])
        )
    timeout = _timeout(conf)
    if timeout is not None:
        kwargs["timeout"] = timeout
    if conf.get("interruptible"):
        kwargs["interruptible"] = conf["interruptible"] == "true"


def _secrets(conf):
    """Turn "KEY, OTHER=ENV_NAME" into the list Flyte wants."""
    declared = conf.get("secrets")
    if not declared:
        return None
    group = conf.get("secret_group") or None
    secrets = []
    for entry in declared.split(","):
        entry = entry.strip()
        if not entry:
            continue
        key, _, env_var = entry.partition("=")
        secrets.append(
            flyte.Secret(key=key.strip(), group=group, as_env_var=(env_var.strip() or None))
        )
    return secrets or None


def _reuse(conf):
    replicas = conf.get("reuse_replicas")
    if not replicas:
        return None
    policy = {"replicas": int(replicas)}
    if conf.get("reuse_idle_ttl"):
        policy["idle_ttl"] = int(conf["reuse_idle_ttl"])
    if conf.get("reuse_concurrency"):
        policy["concurrency"] = int(conf["reuse_concurrency"])
    if conf.get("reuse_scope"):
        policy["scope"] = conf["reuse_scope"]
    return flyte.ReusePolicy(**policy)


def override_kwargs(spec):
    """Turn a spec into keyword arguments for ``TaskTemplate.override``."""
    conf = decode_spec(spec)
    kwargs = {}
    resources = _resources(conf)
    if resources is not None:
        kwargs["resources"] = resources
    cache = _cache(conf)
    if cache is not None:
        kwargs["cache"] = cache
    _reliability(conf, kwargs)
    secrets = _secrets(conf)
    if secrets is not None:
        kwargs["secrets"] = secrets
    reuse = _reuse(conf)
    if reuse is not None:
        if "resources" in kwargs:
            # Flyte rejects this deep inside override(); say it in the SDK's
            # own terms, because the two settings usually come from different
            # places — resources from the environment, Reuse from a call site.
            raise ValueError(
                "flyte: an action cannot combine Resources with Reuse. A "
                "reusable container already has the resources of the pool it "
                "belongs to, so Flyte will not let a task override them. "
                "Drop the Reuse(...), or drop the resources from the "
                "environment and every call site that reaches this action."
            )
        kwargs["reusable"] = reuse
    return kwargs


def configured(task, spec):
    """``task`` with its spec applied — or unchanged, when there is none."""
    kwargs = override_kwargs(spec)
    return task.override(**kwargs) if kwargs else task


def identifier(text):
    """A Python identifier derived from an action FQN ("demo.hello")."""
    name = re.sub(r"\W", "_", text).strip("_") or "action"
    return "a_" + name if name[0].isdigit() else name


def reason(lines):
    """The Mojo error out of a failed run's output, without the boilerplate."""
    kept = []
    for line in lines:
        line = line.strip()
        if not line or any(noise in line for noise in _NOISE):
            continue
        if line.startswith(_PANIC):
            return line[len(_PANIC):]
        kept.append(line)
    return " | ".join(kept[-3:])


# --------------------------------------------------------------------------
# Driving one action
# --------------------------------------------------------------------------

class _Run:
    """Everything the pump needs while driving one action."""

    def __init__(self, proc, dispatch, journal):
        self.proc = proc
        self.dispatch = dispatch
        self.journal = list(journal)
        self.logs = []
        self.groups = []     # flyte.group contexts the program has opened

    def close_groups(self):
        """Leave any group the program opened but never closed."""
        while self.groups:
            try:
                self.groups.pop().__exit__(None, None, None)
            except Exception:
                pass


async def drive(here, action, args, dispatch, journal=()):
    """Run ``action`` of the bundled Mojo binary, servicing what it asks for.

    ``dispatch(fqn, args, journal, spec)`` returns an awaitable that runs
    ``fqn`` as a child action with that configuration applied; the generated shim maps each known action to its own named
    Flyte task and falls back to a generic one for anything it did not
    discover. ``journal`` carries results already computed for this run.
    """
    binary = os.path.join(here, BINARY_NAME)
    os.chmod(binary, 0o755)
    proc = subprocess.Popen(
        [binary, *args],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
        env={
            **os.environ,
            "LD_LIBRARY_PATH": here,
            "FLYTE_MOJO_ACTION": action,
            "FLYTE_MOJO_PROTOCOL": "1",
            "FLYTE_MOJO_JOURNAL": "\n".join(journal),
        },
    )

    run = _Run(proc, dispatch, journal)
    result = None
    failure = None
    try:
        result = await _pump(run)
    except _WorkerExit:
        pass  # the exit code below is the real story
    except Exception as exc:  # a child action or span failed
        failure = exc
    finally:
        run.close_groups()

    # Closing stdin unblocks a worker still waiting on a reply, so this
    # cannot hang even when we are unwinding from a failure.
    try:
        rest_out, rest_err = await asyncio.to_thread(proc.communicate, None, 120)
    except Exception:
        proc.kill()
        rest_out, rest_err = "", ""
    for line in (rest_out + rest_err).splitlines():
        run.logs.append(line)
        print(line)

    if failure is not None:
        raise failure
    if proc.returncode != 0:
        raise RuntimeError(
            "mojo action %s failed (exit %s): %s"
            % (action, proc.returncode, reason(run.logs) or "no output")
        )
    if result is None:
        raise RuntimeError(
            "mojo action %s produced no result: the program ran to completion "
            "without reaching a task bound as %r" % (action, action)
        )
    return result


async def _pump(run):
    """Read control lines until the worker yields a value.

    At the top level that value is the action's result; inside a span it is
    the span's result, because the same loop serves both.
    """
    while True:
        line = await asyncio.to_thread(run.proc.stdout.readline)
        if line == "":
            raise _WorkerExit()
        line = line.rstrip("\n")

        if line.startswith(OUTPUT_MARK):
            return line[len(OUTPUT_MARK):]

        if line.startswith(CALL_MARK):
            await _service_call(run, _decode_row(line[len(CALL_MARK):]))
            continue

        if line.startswith(GROUP_MARK):
            fields = _decode_row(line[len(GROUP_MARK):])
            if fields[0] == "begin":
                # Entered and left across separate control lines, so the
                # context has to be driven by hand rather than with `with`.
                context = flyte.group(fields[1])
                context.__enter__()
                run.groups.append(context)
            elif run.groups:
                run.groups.pop().__exit__(None, None, None)
            continue

        if line.startswith(SPAN_MARK):
            fields = _decode_row(line[len(SPAN_MARK):])
            if fields[0] == "begin":
                fqn, span_args = fields[1], fields[2:]
                await _traced(fqn, run)(span_args)
                continue
            output = fields[1] if len(fields) > 1 else ""
            error = fields[2] if len(fields) > 2 else ""
            if error:
                raise RuntimeError(error)
            return output

        run.logs.append(line)
        print(line)


async def _service_call(run, fields):
    """Launch child actions on the worker's behalf and reply with the result.

    Siblings of a fan-out all see the same journal snapshot — they are
    independent, so none of them should be waiting on the others.

    Nothing here opens a group: a child action belongs to whatever group the
    program itself opened with ``with group(...)``, or to none.
    """
    kind, fqn, spec, rest = fields[0], fields[1], fields[2], fields[3:]
    snapshot = list(run.journal)
    try:
        if kind == "map":
            outputs = await asyncio.gather(
                *(run.dispatch(fqn, [item], snapshot, spec) for item in rest)
            )
            for item, output in zip(rest, outputs):
                run.journal.append(_encode_row([fqn, output, item]))
            reply = ["OK", *outputs]
        else:
            output = await run.dispatch(fqn, list(rest), snapshot, spec)
            run.journal.append(_encode_row([fqn, output, *rest]))
            reply = ["OK", output]
    except Exception as exc:
        reply = ["ERR", "%s: %s" % (fqn, exc)]
    run.proc.stdin.write(_encode_row(reply) + "\n")
    run.proc.stdin.flush()


def _traced(fqn, run):
    """A flyte.trace-wrapped span named after the Mojo trace.

    Its body pumps the worker until the span closes, so the trace context is
    open for exactly the time the Mojo code spends inside it.
    """

    async def span(args: list[str]) -> str:
        return await _pump(run)

    span.__name__ = identifier(fqn)
    span.__qualname__ = span.__name__
    return flyte.trace(span)
