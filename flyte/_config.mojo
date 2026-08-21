"""Configuration and execution mode.

``init_from_config()`` does double duty: it reads the Flyte config and it
decides how the rest of the program runs. A config that names a cluster
endpoint puts the program in *remote* mode, so a later ``run[...]`` ships
this very program to that cluster instead of executing it in-process. Pass
``mode="local"`` to read the config without opting into remote execution.
"""
from std.sys import argv

from ._mode import is_worker
from ._state import state

comptime MODE_LOCAL: String = "local"
comptime MODE_REMOTE: String = "remote"
comptime MODE_WORKER: String = "worker"


@fieldwise_init
struct Config(ImplicitlyCopyable, Writable):
    var path: String
    var endpoint: String
    var org: String
    var project: String
    var domain: String
    var image_builder: String
    var mode: String
    """One of "local", "remote" (this process drives a cluster) or
    "worker" (this process *is* a task running on the cluster)."""


def _program_path() raises -> String:
    """Path to the running program: the .mojo source under ``mojo run``."""
    var a = argv()
    if len(a) == 0:
        return String("")
    return String(a[0])


def init_from_config(path: String = "", mode: String = "auto") raises -> Config:
    """Load a Flyte config (default: ``~/.flyte/config.yaml``) and set the mode.

    ``mode="auto"`` (the default) selects remote execution when the config
    names an endpoint, and local execution otherwise. ``mode="local"``
    forces in-process execution even against a cluster config.

    Inside an action pod this returns immediately in worker mode: the pod
    has no config file, and no Python interpreter is required to find that
    out.
    """
    if is_worker():
        return Config("", "", "", "", "", "", MODE_WORKER)

    var st = state()
    var cfg = st.config_load(path)
    var endpoint = String(cfg["endpoint"])
    var org = String(cfg["org"])
    var project = String(cfg["project"])
    var domain = String(cfg["domain"])
    var image_builder = String(cfg["image_builder"])

    var resolved: String
    if mode == "auto":
        resolved = MODE_REMOTE if endpoint != "" else MODE_LOCAL
    elif mode == MODE_LOCAL or mode == MODE_REMOTE:
        resolved = mode
    else:
        raise Error("flyte: unknown mode '" + mode + "' (use 'auto', 'local' or 'remote')")

    if resolved == MODE_REMOTE and endpoint == "":
        raise Error(
            "flyte: mode='remote' but the config has no admin.endpoint ("
            + String(st.config_path_used(path))
            + ")"
        )

    st.session_init(path, resolved, _program_path())
    return Config(path, endpoint, org, project, domain, image_builder, resolved)


def mode() raises -> String:
    """The current execution mode of this process."""
    if is_worker():
        return MODE_WORKER
    return String(state().session_mode())
