"""Task configuration that travels with an action.

Flyte lets you say how a task should run — how much CPU it wants, whether to
cache it, how many times to retry. Mojo binds tasks at compile time, so that
configuration is a *compile-time parameter* and the SDK folds it into one
string at bind time:

    comptime env = TaskEnvironment["etl", resources=Resources(cpu="2")]()
    comptime score = env.task[
        f=_score, name="score", resources_override=Resources(cpu="8", gpu=1)
    ]()

``score`` now carries ``cpu=2\\tcpu=8\\tgpu=1``. Fields are read left to right
and the last one wins, so a task override beats its environment without the
encoder needing to know which keys exist.

The string rides along with the action — on the launch for a root action, and
in the ``CALL`` request for a child — and the shim turns it back into
``TaskTemplate.override(...)``. Nothing is registered anywhere and nothing is
parsed out of your source: the configuration goes where the action goes.
"""


struct Resources(ImplicitlyCopyable, Movable):
    """What one action needs to run. Empty fields mean "inherit"."""

    var cpu: String
    var memory: String
    var gpu: Int
    var gpu_type: String

    def __init__(out self, *, cpu: String = "", memory: String = "", gpu: Int = 0, gpu_type: String = ""):
        self.cpu = cpu
        self.memory = memory
        self.gpu = gpu
        self.gpu_type = gpu_type


struct Cache(ImplicitlyCopyable, Movable):
    """Whether to reuse a previous result for the same inputs.

    ``behavior`` is Flyte's: "auto" caches on the inputs and the task version,
    "override" recomputes once and replaces what was cached, "disable" is the
    default. ``version`` pins the cache key yourself, so you can invalidate a
    cache by changing it; ``salt`` separates otherwise identical entries.
    """

    var behavior: String
    var version: String
    var salt: String

    def __init__(out self, behavior: String = "", *, version: String = "", salt: String = ""):
        self.behavior = behavior
        self.version = version
        self.salt = salt


def field(key: String, value: String) -> String:
    """One ``key=value`` field, or nothing at all when the value is unset.

    Unset has to encode as *absent* rather than as an empty value: an empty
    field would override an environment setting with nothing.
    """
    if value == "":
        return String("")
    return key + "=" + _escape(value) + "\t"


def field_int(key: String, value: Int) -> String:
    """As ``field``, treating 0 as unset."""
    if value == 0:
        return String("")
    return key + "=" + String(value) + "\t"


def field_bool(key: String, value: Bool, unset: Bool = False) -> String:
    """As ``field``, for a flag whose default is ``unset``."""
    if value == unset:
        return String("")
    return key + "=" + ("true" if value else "false") + "\t"


def _escape(value: String) -> String:
    """Keep a value on one field: the spec is tab-separated, one line."""
    return value.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


def encode_cache(c: Cache) -> String:
    return (
        field("cache", c.behavior)
        + field("cache_version", c.version)
        + field("cache_salt", c.salt)
    )


def encode_resources(r: Resources) -> String:
    return (
        field("cpu", r.cpu)
        + field("memory", r.memory)
        + field_int("gpu", r.gpu)
        + field("gpu_type", r.gpu_type)
    )
