"""Global state for the Flyte Mojo SDK.

Mojo has no module-level mutable globals, so all mutable SDK state lives in
this Python module, shared by the whole process. The Mojo side talks to it
through a small, flat API. All arguments and results are JSON-safe scalars
or lists of scalars (strings, ints, floats, bools, None) so that crossing
the Mojo/Python boundary never requires custom serialization.

This file is intentionally dependency-free: it only uses the Python
standard library. The only optional third-party import is ``flyte`` (the
Python SDK), which is loaded lazily by ``remote_run`` so that local
execution never needs it.
"""

import os
import time
import uuid

RUNS = {}
_STACK = []
_CURRENT = None
_CONFIG = None
_CONFIG_PATH = ""
_PY_INITIALIZED = False


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
    """Load a Flyte config.yaml (defaults to ~/.flyte/config.yaml)."""
    if not path:
        path = os.path.expanduser(os.path.join("~", ".flyte", "config.yaml"))
    with open(path, "r", encoding="utf-8") as fh:
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

def remote_run(file, task, args):
    """Run a task defined in a Python file on the live Flyte cluster.

    Returns a dict with url, name, phase, and stringified outputs.
    Raises on failure (Mojo sees a Mojo Error).
    """
    import importlib
    import sys

    global _PY_INITIALIZED

    import flyte as pyflyte

    if not _PY_INITIALIZED:
        if _CONFIG_PATH:
            pyflyte.init_from_config(_CONFIG_PATH)
        else:
            pyflyte.init_from_config()
        _PY_INITIALIZED = True

    directory = os.path.dirname(os.path.abspath(file))
    if directory not in sys.path:
        sys.path.insert(0, directory)
    module_name = os.path.basename(file)
    if module_name.endswith(".py"):
        module_name = module_name[:-3]
    module = importlib.import_module(module_name)
    fn = getattr(module, task)

    run = pyflyte.run(fn, *args)
    run.wait()
    outputs = run.outputs
    if callable(outputs):
        outputs = outputs()
    if outputs is None:
        output_list = []
    elif isinstance(outputs, (list, tuple)):
        output_list = [str(o) for o in outputs]
    else:
        output_list = [str(outputs)]
    return {
        "url": run.url,
        "name": run.name,
        "phase": "SUCCEEDED",
        "output": output_list[0] if output_list else "",
        "outputs": output_list,
    }
