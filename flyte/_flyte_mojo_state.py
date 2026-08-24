"""Driver-side internals of the Flyte Mojo SDK.

Mojo has no module-level mutable globals, so all mutable SDK state lives in
this Python module, shared by the whole process. The Mojo side talks to it
through a small, flat API (see ``flyte/_state.mojo``, which locates and
imports this file). All arguments and results are JSON-safe scalars or
lists of scalars, so crossing the Mojo/Python boundary never requires
custom serialization.

It also owns everything a remote run needs on the *developer's machine*:
cross-compiling the program for linux/amd64, generating the per-action
shim, and launching the run. The pod-side half is ``flyte_mojo_shim.py``,
beside this file.

This module is dependency-free apart from the Python ``flyte`` SDK, which is
imported lazily so that local execution never needs it.
"""

import os
import re
import time
import uuid

RUNS = {}
_STACK = []
_CURRENT = None
_CONFIG = None
_CONFIG_PATH = ""
_PY_INITIALIZED = False

# The driver session: where the running .mojo program lives and whether its
# runs execute in-process ("local") or on a cluster ("remote").
_SESSION = {"config_path": "", "mode": "local", "program": ""}


def _new_id(prefix):
    return "%s-%s" % (prefix, uuid.uuid4().hex[:10])


# --------------------------------------------------------------------------
# Run lifecycle
# --------------------------------------------------------------------------

def run_begin(name, fqn, mode, url):
    """Start a new run. Returns the run name."""
    global _CURRENT
    run_name = name if name else _new_id("run")
    run = {
        "name": run_name,
        "fqn": fqn,
        "mode": mode,
        "url": url if url else "local://%s" % run_name,
        "phase": "RUNNING",
        "started": time.time(),
        "ended": None,
        "output": None,
        "error": None,
        "events": [],
    }
    RUNS[run_name] = run
    _CURRENT = run
    del _STACK[:]
    return run_name


def run_finish(output, error):
    """Finish the current run, recording output or error."""
    global _CURRENT
    if _CURRENT is None:
        return
    _CURRENT["phase"] = "FAILED" if error else "SUCCEEDED"
    _CURRENT["ended"] = time.time()
    _CURRENT["output"] = output
    _CURRENT["error"] = error
    _CURRENT = None


def current_run_name():
    if _CURRENT is None:
        return ""
    return _CURRENT["name"]


# --------------------------------------------------------------------------
# Actions: tasks and traces
# --------------------------------------------------------------------------

def action_begin(kind, fqn, args):
    """Begin a task or trace action. Records it under the current run."""
    entry = {
        "id": _new_id(kind[:4]),
        "kind": kind,
        "fqn": fqn,
        "args": list(args),
        "depth": len(_STACK),
        "started": time.time(),
        "ended": None,
        "phase": "RUNNING",
        "output": None,
        "error": None,
    }
    if _CURRENT is not None:
        _CURRENT["events"].append(entry)
    _STACK.append(entry)
    return entry["id"]


def action_finish(output, error):
    """Finish the most recent action, recording output or error."""
    if not _STACK:
        return
    entry = _STACK.pop()
    entry["ended"] = time.time()
    entry["phase"] = "FAILED" if error else "SUCCEEDED"
    entry["output"] = output
    entry["error"] = error


# --------------------------------------------------------------------------
# Checkpoints (local mode)
#
# There are no attempts in a local run, so this is a single slot that lives
# for the length of the process: enough to exercise the code path, not
# durable. In a worker the shim persists them through Flyte instead.
# --------------------------------------------------------------------------

_CHECKPOINT = {"data": ""}


def checkpoint_save(text):
    _CHECKPOINT["data"] = text
    return ""


def checkpoint_load():
    return _CHECKPOINT["data"]


# --------------------------------------------------------------------------
# Groups: a named region of a run, recorded as a level in the report
# --------------------------------------------------------------------------

def group_begin(name):
    """Open a named group. Outside a run there is nothing to group."""
    if _CURRENT is None:
        return ""
    entry = {
        "id": _new_id("grp"),
        "kind": "group",
        "fqn": name,
        "args": [],
        "depth": len(_STACK),
        "started": time.time(),
        "ended": None,
        "phase": "RUNNING",
        "output": None,
        "error": None,
    }
    _CURRENT["events"].append(entry)
    _STACK.append(entry)
    return entry["id"]


def group_end():
    """Close the innermost group, if the stack top is one."""
    if not _STACK or _STACK[-1]["kind"] != "group":
        return
    entry = _STACK.pop()
    entry["ended"] = time.time()
    entry["phase"] = "SUCCEEDED"


# --------------------------------------------------------------------------
# Context
# --------------------------------------------------------------------------

def ctx_info():
    if _CURRENT is None:
        return {"run": "", "action": "", "depth": 0, "phase": "", "mode": ""}
    top = _STACK[-1] if _STACK else None
    return {
        "run": _CURRENT["name"],
        "action": top["fqn"] if top else _CURRENT["fqn"],
        "depth": len(_STACK),
        "phase": _CURRENT["phase"],
        "mode": _CURRENT["mode"],
    }


# --------------------------------------------------------------------------
# Run queries and reporting
# --------------------------------------------------------------------------

def run_get(name):
    run = RUNS.get(name)
    if run is None:
        return None
    return {
        "name": run["name"],
        "url": run["url"],
        "phase": run["phase"],
        "fqn": run["fqn"],
        "mode": run["mode"],
        "output": run["output"],
        "error": run["error"],
        "event_count": len(run["events"]),
        "duration": (run["ended"] if run["ended"] is not None else time.time()) - run["started"],
    }


def runs_list():
    return list(RUNS.keys())


def report(name):
    """A readable trace report for a run: the tree of task/trace actions."""
    run = RUNS.get(name)
    if run is None:
        return "no run named %s" % name
    nl = chr(10)
    lines = []
    lines.append("Run %s  [%s]" % (run["name"], run["phase"]))
    lines.append("  url:   %s" % run["url"])
    lines.append("  fqn:   %s   mode: %s" % (run["fqn"], run["mode"]))
    for ev in run["events"]:
        indent = "  " * (1 + ev["depth"])
        mark = "OK " if ev["phase"] == "SUCCEEDED" else "ERR"
        dur_ms = (ev["ended"] if ev["ended"] is not None else 0.0) - ev["started"]
        if ev["kind"] == "group":
            lines.append("%s-- group %s  [%.1fms]" % (indent, ev["fqn"], dur_ms * 1000.0))
            continue
        args = ", ".join(str(a) for a in ev["args"])
        out = " -> %s" % ev["output"] if ev["output"] is not None else ""
        err = "  ! %s" % ev["error"] if ev["error"] else ""
        lines.append(
            "%s%s %s %s(%s)%s%s  [%.1fms]"
            % (indent, mark, ev["kind"], ev["fqn"], args, out, err, dur_ms * 1000.0)
        )
    if run["output"] is not None:
        lines.append("output: %s" % run["output"])
    if run["error"]:
        lines.append("error:  %s" % run["error"])
    return nl.join(lines)


# --------------------------------------------------------------------------
# Config
# --------------------------------------------------------------------------

def config_set(cfg):
    global _CONFIG
    _CONFIG = cfg


def config_get():
    return _CONFIG


def session_init(config_path, mode, program):
    """Record what init_from_config() resolved: config, mode, and program."""
    global _CONFIG_PATH
    _SESSION["config_path"] = config_path or ""
    _SESSION["mode"] = mode
    _SESSION["program"] = os.path.abspath(program) if program else ""
    _CONFIG_PATH = config_path or ""
    return _SESSION["mode"]


def session_mode():
    """"local" or "remote" — how run[...] should execute."""
    return _SESSION["mode"]


def config_path_used(path):
    """The config file a given (possibly empty) path resolves to."""
    if path:
        return path
    return os.path.expanduser(os.path.join("~", ".flyte", "config.yaml"))


def config_set_path(path):
    global _CONFIG_PATH
    _CONFIG_PATH = path


def config_get_path():
    return _CONFIG_PATH


def _parse_simple_yaml(text):
    """Minimal YAML reader for two-level ``key: value`` nesting (fallback)."""
    out = {}
    current = None
    for raw in text.splitlines():
        if not raw.strip() or raw.strip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip())
        key, _, value = raw.strip().partition(":")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        if indent == 0:
            if value:
                out[key] = value
                current = None
            else:
                out[key] = {}
                current = out[key]
        else:
            if current is None:
                current = {}
                out[key] = current
            current[key] = value
    return out


def config_load(path):
    """Load a Flyte config.yaml (defaults to ~/.flyte/config.yaml).

    A missing *default* config is not an error: it simply means there is no
    cluster to talk to, so the program runs locally. A missing *explicit*
    path is an error, because the caller clearly meant that file.
    """
    explicit = bool(path)
    resolved = config_path_used(path)
    if not os.path.exists(resolved):
        if explicit:
            raise RuntimeError("flyte: no such config file: %s" % resolved)
        return {"found": "", "endpoint": "", "org": "", "project": "", "domain": "", "image_builder": ""}
    with open(resolved, "r", encoding="utf-8") as fh:
        text = fh.read()
    data = None
    try:
        import yaml  # optional dependency

        data = yaml.safe_load(text)
        if not isinstance(data, dict):
            data = None
    except ImportError:
        data = None
    if data is None:
        data = _parse_simple_yaml(text)

    def pick(*chains):
        for chain in chains:
            node = data
            for key in chain:
                if isinstance(node, dict) and key in node and node[key] is not None:
                    node = node[key]
                else:
                    node = None
                    break
            if node is not None:
                return str(node)
        return ""

    return {
        "found": resolved,
        "endpoint": pick(("admin", "endpoint"), ("endpoint",), ("admin_endpoint",)),
        "org": pick(("task", "org"), ("org",)),
        "project": pick(("task", "project"), ("project",)),
        "domain": pick(("task", "domain"), ("domain",)),
        "image_builder": pick(("image", "builder"), ("image_builder",), ("builder",)),
    }


# --------------------------------------------------------------------------
# Test helpers (used by the Mojo test suite)
# --------------------------------------------------------------------------

_TEST = {"passed": 0, "failed": 0}


def test_check(ok, label):
    if ok:
        _TEST["passed"] += 1
    else:
        _TEST["failed"] += 1
    print(("  PASS " if ok else "  FAIL ") + label, flush=True)


def test_tally():
    return dict(_TEST)




# --------------------------------------------------------------------------
# Remote (live cluster) execution — drives the Python flyte SDK
# --------------------------------------------------------------------------

_PYFLYTE = None


def _pyflyte():
    """Import and initialize the Python flyte SDK once per process."""
    global _PY_INITIALIZED, _PYFLYTE
    import flyte as pyflyte
    import flyte.remote  # noqa: F401 — expose pyflyte.remote for ActionDetails

    if not _PY_INITIALIZED:
        if _CONFIG_PATH:
            pyflyte.init_from_config(_CONFIG_PATH)
        else:
            pyflyte.init_from_config()
        _PY_INITIALIZED = True
    _PYFLYTE = pyflyte
    return pyflyte


def _await_run(pyflyte, run):
    """Wait for a launched run and return its outputs as a list of strings.

    ``run.wait()`` does not raise on failure, so the action phase is checked
    explicitly and the cluster's error message is pulled back out.
    """
    run.wait()
    action = run.action
    phase = action.phase
    phase_name = getattr(phase, "name", None) or str(phase)
    if "SUCCEEDED" not in phase_name.upper():
        msg = ""
        try:
            details = pyflyte.remote.ActionDetails.get_details(action.action_id)
            if details.error_info is not None:
                msg = details.error_info.message
        except Exception:
            pass
        raise RuntimeError(
            "remote run %s failed (%s): %s" % (run.name, phase_name, msg or "no error details")
        )

    outputs = run.outputs
    if callable(outputs):
        outputs = outputs()
    if outputs is None:
        return []
    if isinstance(outputs, (list, tuple)):
        return [str(o) for o in outputs]
    return [str(outputs)]


def remote_run(file, task, args):
    """Run a task defined in a *Python* file on the live Flyte cluster."""
    import importlib
    import sys

    pyflyte = _pyflyte()

    # A path relative to the .mojo program is friendlier than one relative to
    # whatever directory the user happened to run from.
    if not os.path.exists(file) and _SESSION["program"]:
        beside = os.path.join(os.path.dirname(_SESSION["program"]), file)
        if os.path.exists(beside):
            file = beside

    directory = os.path.dirname(os.path.abspath(file))
    if directory not in sys.path:
        sys.path.insert(0, directory)
    module_name = os.path.basename(file)
    if module_name.endswith(".py"):
        module_name = module_name[:-3]
    module = importlib.import_module(module_name)
    fn = getattr(module, task)

    run = pyflyte.run(fn, *args)
    output_list = _await_run(pyflyte, run)
    return {
        "url": run.url,
        "name": run.name,
        "phase": "SUCCEEDED",
        "output": output_list[0] if output_list else "",
        "outputs": output_list,
    }


# --------------------------------------------------------------------------
# Control plane: asking the cluster about work, rather than giving it work
# --------------------------------------------------------------------------

def _phase_name(value):
    return getattr(value, "name", None) or str(value)


def _run_row(run):
    return [run.name, _phase_name(run.phase), run.url or ""]


def cp_runs(limit):
    """Recent runs, newest first, as [name, phase, url] rows."""
    import flyte.remote as remote

    _pyflyte()
    return [_run_row(run) for run in remote.Run.listall(limit=int(limit))]


def cp_status(name):
    """One run's current state."""
    import flyte.remote as remote

    _pyflyte()
    run = remote.Run.get(name=name)
    run.sync()
    return _run_row(run)


def cp_abort(name):
    """Stop a run and everything under it. Aborting a finished run is a no-op."""
    import flyte.remote as remote

    _pyflyte()
    run = remote.Run.get(name=name)
    run.abort()
    run.sync()
    return _run_row(run)


def cp_logs(name, lines):
    """The tail of a run's logs, as one string."""
    import flyte.remote as remote

    _pyflyte()
    run = remote.Run.get(name=name)
    collected = []
    try:
        stream = run.get_logs(max_lines=int(lines))
    except TypeError:
        stream = run.get_logs()
    for chunk in stream:
        text = chunk if isinstance(chunk, str) else str(chunk)
        # Chunks arrive one log line at a time, without their newline.
        collected.extend(text.splitlines() or [text])
    return "\n".join(collected[-int(lines):] if lines else collected)


def cp_rerun(name):
    """Run the same task again with the same inputs."""
    pyflyte = _pyflyte()
    run = pyflyte.rerun(run_name=name)
    return _run_row(run)


# --------------------------------------------------------------------------
# Compiled-Mojo remote execution
#
# The user writes one .mojo file. To run one of its actions on the cluster
# we compile that same file for linux/amd64, generate a one-task Python shim
# that execs the binary with FLYTE_MOJO_ACTION set, and launch it. The shim
# is the only Python that runs in the pod; the task body is native Mojo.
# --------------------------------------------------------------------------

MOJO_VERSION = "1.0.0"
BUILDER_IMAGE = "flyte-mojo-builder:%s" % MOJO_VERSION
# Not a dot-directory: Flyte derives the task's module path from where the
# shim sits in the code bundle, so every path segment must be a valid Python
# identifier.
WORKDIR = "_flyte_mojo"
PACKAGE = "flyte"
BRIDGE_MODULE = "_flyte_mojo_state.py"   # this file; how the package is recognised
BINARY_NAME = "task_binary"
OUTPUT_MARK = "__FLYTE_MOJO_OUTPUT__:"
ACTION_TIMEOUT = 900

# Runtime shared objects a compiled Mojo binary links against; copied out of
# the builder image and bundled with the task.
RUNTIME_LIBS = (
    "libKGENCompilerRTShared.so",
    "libMSupportGlobals.so",
    "libAsyncRTRuntimeGlobals.so",
)

_DOCKERFILE = '''# Generated by the Flyte Mojo SDK.
# Cached linux/amd64 builder for compiling Mojo task binaries. The heavy
# layer (pip install mojo) is a Docker cache hit after the first build, so
# recompiling a changed source takes seconds rather than minutes.
FROM python:3.12-slim

RUN apt-get update -qq \\
    && apt-get install -y -qq --no-install-recommends gcc libc6-dev \\
    && rm -rf /var/lib/apt/lists/*

RUN pip install --quiet --no-cache-dir "mojo==%(version)s"

ENV MOJO_LIB_DIR=/usr/local/lib/python3.12/site-packages/modular/lib
WORKDIR /src
'''

SHIM_RUNTIME = "flyte_mojo_shim.py"
SHIM_MODULE = "flyte_mojo_shim"

_SHIM = """\"\"\"Generated by the Flyte Mojo SDK — do not edit.

Entry point for the %(action)s action of %(program)s. The real work is in
flyte_mojo_shim.py, bundled next to this file.
\"\"\"
import os
import sys

import flyte

_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

import flyte_mojo_shim as shim

_ACTION = %(action)r
_INCLUDE = tuple(
    os.path.join(_HERE, name) for name in (%(binary)r, %(runtime)r, *%(libs)r)
)

env = flyte.TaskEnvironment(name=%(env_name)r, include=_INCLUDE%(image)s)

# One Flyte task per Mojo action, so the UI shows real names rather than a
# single generic worker. Anything not discovered falls back to mojo_action.
_TASKS = {}


@env.task
async def mojo_action(action: str, args: list[str], journal: list[str]) -> str:
    \"\"\"Any action of the bundled program, run as a child action.\"\"\"
    return await shim.drive(_HERE, action, args, _dispatch, journal)

%(tasks)s

def _dispatch(action, args, journal, spec=""):
    \"\"\"An awaitable running `action` as a child action, so configured.\"\"\"
    task = _TASKS.get(action)
    if task is None:
        return shim.configured(mojo_action, spec)(
            action=action, args=args, journal=journal
        )
    return shim.configured(task, spec)(args=args, journal=journal)
"""

_SHIM_TASK = """
@env.task(short_name=%(action)r)
async def %(fn)s(args: list[str], journal: list[str]) -> str:
    \"\"\"The %(action)s action.\"\"\"
    return await shim.drive(_HERE, %(action)r, args, _dispatch, journal)


_TASKS[%(action)r] = %(fn)s

"""


# Bindings are comptime literals by design, so the set of actions a program
# defines can be read straight off the source:
#     comptime env = TaskEnvironment["etl"]()
#     comptime score = env.task[f=_score, name="score"]()
_ENV_BINDING = re.compile(r'comptime\s+(\w+)\s*=\s*TaskEnvironment\[\s*"([^"]+)"')
_TASK_BINDING = re.compile(
    r'comptime\s+\w+\s*=\s*(\w+)\.task\[[^\]]*?\bname\s*=\s*"([^"]+)"'
)


def discover_actions(program):
    """The task FQNs a .mojo program binds, best-effort.

    A miss is not fatal: an action with no named task still runs through the
    generic dispatcher, it just shows up in the UI under its group name.
    """
    try:
        with open(program, "r", encoding="utf-8") as handle:
            source = handle.read()
    except OSError:
        return []
    envs = dict(_ENV_BINDING.findall(source))
    found = []
    for var, name in _TASK_BINDING.findall(source):
        env_name = envs.get(var)
        if env_name:
            found.append("%s.%s" % (env_name, name))
    if not found:
        # Reading bindings out of source is a convenience, and it degrades
        # quietly — every action still runs, just under a generic name. Say so
        # rather than leaving someone to wonder why the UI looks wrong.
        _log(
            "note: found no task bindings in %s, so actions will appear as "
            "'mojo_action' in the UI" % os.path.basename(program)
        )
    return sorted(set(found))


def shim_runtime():
    """The pod-side runtime, imported here for the helpers the driver shares.

    Loading it by path rather than by name keeps the two halves in step: the
    spec the driver encodes is decoded by exactly the code that will run in
    the pod.
    """
    import importlib.util
    import sys

    if SHIM_MODULE in sys.modules:
        return sys.modules[SHIM_MODULE]
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), SHIM_RUNTIME)
    spec = importlib.util.spec_from_file_location(SHIM_MODULE, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[SHIM_MODULE] = module
    spec.loader.exec_module(module)
    return module


def _log(message):
    print("[flyte-mojo] %s" % message, flush=True)


def _identifier(text):
    """A Python identifier derived from an action FQN ("demo.hello")."""
    import re

    name = re.sub(r"\W", "_", text).strip("_") or "action"
    if name[0].isdigit():
        name = "a_" + name
    return name


def sdk_root(program):
    """The directory holding the ``flyte/`` package — the build and bundle root.

    Not the program's own directory: an example under ``examples/`` compiles
    and bundles against the SDK beside it, so the root has to be their common
    ancestor.
    """
    override = os.environ.get("FLYTE_MOJO_SDK")
    if override:
        return os.path.dirname(os.path.abspath(override))
    here = os.path.dirname(os.path.abspath(program))
    for _ in range(8):
        if os.path.exists(os.path.join(here, PACKAGE, BRIDGE_MODULE)):
            return here
        parent = os.path.dirname(here)
        if parent == here:
            break
        here = parent
    raise RuntimeError(
        "flyte: cannot find the %s/ package above %s — a remote run compiles "
        "the program against it, so the two must share a directory tree."
        % (PACKAGE, program)
    )


def _walk_mojo(directory):
    """Every .mojo file under ``directory``."""
    found = []
    for dirpath, dirnames, filenames in os.walk(directory):
        dirnames[:] = [
            d for d in dirnames
            if not d.startswith(".") and d not in ("__pycache__", "node_modules", WORKDIR)
        ]
        for filename in filenames:
            if filename.endswith(".mojo"):
                found.append(os.path.join(dirpath, filename))
    return found


def _mojo_sources(root, program):
    """Every .mojo file that can affect this program's build.

    The program, the SDK it compiles against, and any package in a
    subdirectory beside it. Sibling programs are skipped, so editing one
    example does not invalidate another's cached build.
    """
    program = os.path.abspath(program)
    found = [program] + _walk_mojo(os.path.join(root, PACKAGE))
    beside = os.path.dirname(program)
    for entry in sorted(os.listdir(beside)):
        path = os.path.join(beside, entry)
        if entry.startswith(".") or entry in ("__pycache__", WORKDIR, PACKAGE):
            continue
        if os.path.isdir(path):
            found += _walk_mojo(path)
    return sorted(set(found))


def _fingerprint(root, program):
    """Content hash of the build inputs — the build cache key."""
    import hashlib

    digest = hashlib.sha256()
    digest.update(MOJO_VERSION.encode())
    digest.update(os.path.relpath(program, root).encode())
    for path in _mojo_sources(root, program):
        digest.update(os.path.relpath(path, root).encode())
        with open(path, "rb") as handle:
            digest.update(handle.read())
    return digest.hexdigest()[:12]


def _docker(args, what):
    """Run a docker command, turning failure into a readable error."""
    import subprocess

    try:
        proc = subprocess.run(args, capture_output=True, text=True)
    except FileNotFoundError:
        raise RuntimeError(
            "flyte: docker is required to build linux/amd64 Mojo task binaries, "
            "but the 'docker' command was not found on PATH."
        )
    if proc.returncode != 0:
        detail = (proc.stderr.strip() or proc.stdout.strip() or "no output")
        raise RuntimeError("flyte: %s failed:\n%s" % (what, detail))
    return proc


def _ensure_builder_image(root):
    import subprocess

    probe = subprocess.run(
        ["docker", "image", "inspect", BUILDER_IMAGE], capture_output=True
    )
    if probe.returncode == 0:
        return
    context = os.path.join(root, WORKDIR)
    os.makedirs(context, exist_ok=True)
    with open(os.path.join(context, "Dockerfile"), "w", encoding="utf-8") as handle:
        handle.write(_DOCKERFILE % {"version": MOJO_VERSION})
    _log("building the %s image (one time, ~1 min)..." % BUILDER_IMAGE)
    _docker(
        ["docker", "build", "--platform", "linux/amd64", "-t", BUILDER_IMAGE, context],
        "docker build of %s" % BUILDER_IMAGE,
    )


def build_program(root, program):
    """Compile ``program`` for linux/amd64. Returns the build directory.

    Cached on the content of every .mojo file under ``root``, so an unchanged
    program is a no-op and a changed one is a ~15s recompile.
    """
    import shlex

    fingerprint = _fingerprint(root, program)
    outdir = os.path.join(root, WORKDIR, "build_%s" % fingerprint)
    artifacts = [os.path.join(outdir, BINARY_NAME)] + [
        os.path.join(outdir, lib) for lib in RUNTIME_LIBS
    ]
    if all(os.path.exists(path) for path in artifacts):
        return outdir

    _ensure_builder_image(root)
    os.makedirs(outdir, exist_ok=True)
    rel_out = os.path.relpath(outdir, root)
    rel_src = os.path.relpath(program, root)
    _log("compiling %s for linux/amd64 (%s)..." % (rel_src, fingerprint))

    # -I /src so a program in a subdirectory can still import the package.
    script = "set -e; mojo build -O3 -I /src -o %s %s; cp %s %s/" % (
        shlex.quote("/src/%s/%s" % (rel_out, BINARY_NAME)),
        shlex.quote("/src/%s" % rel_src),
        # MOJO_LIB_DIR is set by the builder image; it must stay unquoted so
        # the shell expands it, and the lib names are fixed constants above.
        " ".join('"$MOJO_LIB_DIR"/%s' % lib for lib in RUNTIME_LIBS),
        shlex.quote("/src/%s" % rel_out),
    )
    _docker(
        [
            "docker", "run", "--rm",
            "--platform", "linux/amd64",
            "--user", "%d:%d" % (os.getuid(), os.getgid()),
            "-e", "HOME=/tmp",
            "-v", "%s:/src" % root,
            "-w", "/src",
            BUILDER_IMAGE,
            "bash", "-lc", script,
        ],
        "mojo build of %s" % rel_src,
    )
    return outdir


def _write_if_changed(path, content):
    existing = None
    if os.path.exists(path):
        with open(path, "r", encoding="utf-8") as handle:
            existing = handle.read()
    if existing != content:
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content)


def _write_shim(outdir, action, env_name, program, image=""):
    """Stage the pod-side runtime and the shim for ``action``.

    Returns (shim path, task function name).
    """
    source_runtime = os.path.join(os.path.dirname(os.path.abspath(__file__)), SHIM_RUNTIME)
    if not os.path.exists(source_runtime):
        raise RuntimeError(
            "flyte: %s is missing from the SDK package — it is the code that "
            "drives the Mojo binary inside the pod." % SHIM_RUNTIME
        )
    with open(source_runtime, "r", encoding="utf-8") as handle:
        _write_if_changed(os.path.join(outdir, SHIM_RUNTIME), handle.read())

    actions = sorted(set(discover_actions(program)) | {action})
    tasks = "".join(
        _SHIM_TASK % {"action": fqn, "fn": _identifier(fqn)} for fqn in actions
    )

    fn = _identifier(action)
    path = os.path.join(outdir, "action_%s.py" % fn)
    _write_if_changed(path, _SHIM % {
        "action": action,
        "program": os.path.basename(program),
        "binary": BINARY_NAME,
        "runtime": SHIM_RUNTIME,
        "libs": list(RUNTIME_LIBS),
        "env_name": env_name,
        "tasks": tasks,
        # Flyte resolves the image when the environment is built, so this is
        # the one setting that cannot ride along with the action.
        "image": (", image=%r" % image) if image else "",
    })
    return path, fn


def _load_module(path, name):
    import importlib.util
    import sys

    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def _run_name(candidate):
    """Flyte accepts lowercase alphanumeric run names; drop anything else."""
    import re

    if candidate and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,62}", candidate):
        return candidate
    return None


def remote_run_mojo(action, args, run_name="", spec=""):
    """Run action ``action`` of the running .mojo program on the cluster.

    ``spec`` is the action's configuration, encoded by ``flyte/_spec.mojo``.
    """
    program = _SESSION["program"]
    if not program:
        raise RuntimeError(
            "flyte: remote mode is active but the running program is unknown. "
            "Call init_from_config() from your .mojo file before run[...]."
        )
    if not os.path.exists(program):
        raise RuntimeError(
            "flyte: cannot find the running program at %s — remote mode needs "
            "the .mojo source to compile a task binary from." % program
        )
    root = sdk_root(program)

    pyflyte = _pyflyte()
    outdir = build_program(root, program)
    env_name = "mojo_%s" % _identifier(os.path.splitext(os.path.basename(program))[0])
    image = shim_runtime().decode_spec(spec).get("image", "")
    shim_path, fn_name = _write_shim(outdir, action, env_name, program, image)
    module = _load_module(shim_path, "_flyte_mojo_%s" % fn_name)
    fn = shim_runtime().configured(getattr(module, fn_name), spec)

    _log("launching %s on the cluster..." % action)
    wire_args = [str(a) for a in args]
    name = _run_name(run_name)
    if name:
        run = pyflyte.with_runcontext(name=name).run(fn, wire_args, [])
    else:
        run = pyflyte.run(fn, wire_args, [])

    run_begin(run.name, action, "remote", run.url)
    action_begin("task", action, wire_args)
    try:
        output_list = _await_run(pyflyte, run)
    except BaseException as exc:
        action_finish(None, str(exc))
        run_finish(None, str(exc))
        raise
    output = output_list[0] if output_list else ""
    action_finish(output, None)
    run_finish(output, None)
    return {
        "url": run.url,
        "name": run.name,
        "phase": "SUCCEEDED",
        "output": output,
        "outputs": output_list,
    }
