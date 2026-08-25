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


struct Backoff(ImplicitlyCopyable, Movable):
    """The pacing between retries.

    The wait before the n-th retry (0-indexed) is ``min(base * factor**n,
    cap)``: with ``base=10, factor=2`` the waits are 10s, 20s, 40s, ... All
    values are in seconds. A ``cap`` is required whenever ``factor`` is
    greater than 1, or the delay grows without bound — Flyte checks this when
    the action is configured.
    """

    var base: Int
    var factor: Float64
    var cap: Int

    def __init__(out self, *, base: Int = 0, factor: Float64 = 1.0, cap: Int = 0):
        self.base = base
        self.factor = factor
        self.cap = cap


struct RetryStrategy(ImplicitlyCopyable, Movable):
    """How many times to try again, and how to pace the attempts.

    ``count`` is the number of retries — an action with ``count=2`` gets up
    to 3 attempts in total. A bare ``Int`` becomes a strategy with that
    count. ``backoff`` spaces the attempts out; without one, retries fire
    back-to-back.
    """

    var count: Int
    var backoff: Backoff

    @implicit
    def __init__(out self, count: Int):
        self.count = count
        self.backoff = Backoff()

    def __init__(out self, *, count: Int = 0, backoff: Backoff = Backoff()):
        self.count = count
        self.backoff = backoff


struct Timeout(ImplicitlyCopyable, Movable):
    """Wall-clock bounds on an action, in seconds.

    Three independent bounds, each optional: zero means unlimited.
    ``max_runtime`` bounds one attempt's running time, ``max_queued_time``
    how long an attempt may wait to be scheduled, and ``deadline`` the total
    wall-clock across every attempt. A bare ``Int`` becomes a ``max_runtime``
    bound, as in the Python SDK.
    """

    var max_runtime: Int
    var max_queued_time: Int
    var deadline: Int

    @implicit
    def __init__(out self, seconds: Int):
        self.max_runtime = seconds
        self.max_queued_time = 0
        self.deadline = 0

    def __init__(out self, *, max_runtime: Int = 0, max_queued_time: Int = 0, deadline: Int = 0):
        self.max_runtime = max_runtime
        self.max_queued_time = max_queued_time
        self.deadline = deadline


struct Reliability(ImplicitlyCopyable, Movable):
    """What to do when an action fails, hangs, or is evicted.

    ``retries`` is a ``RetryStrategy`` — or a bare ``Int`` of how many times
    to try again — ``timeout`` is a ``Timeout`` — or a bare ``Int`` of
    seconds for one attempt's running time — and ``interruptible`` allows the
    action onto preemptible capacity — cheaper, at the cost of being
    restarted when the node is reclaimed. An empty strategy, an empty timeout
    and ``False`` mean "inherit", so an environment's setting survives a task
    that says nothing.
    """

    var retries: RetryStrategy
    var timeout: Timeout
    var interruptible: Bool

    def __init__(out self, *, retries: RetryStrategy = RetryStrategy(), timeout: Timeout = Timeout(), interruptible: Bool = False):
        self.retries = retries
        self.timeout = timeout
        self.interruptible = interruptible


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


def encode_reliability(r: Reliability) -> String:
    var spec = field_int("retries", r.retries.count)
    if r.retries.backoff.base > 0:
        spec += field_int("backoff_base", r.retries.backoff.base)
        spec += field("backoff_factor", String(r.retries.backoff.factor))
        spec += field_int("backoff_cap", r.retries.backoff.cap)
    return (
        spec
        + field_int("timeout_runtime", r.timeout.max_runtime)
        + field_int("timeout_queued", r.timeout.max_queued_time)
        + field_int("timeout_deadline", r.timeout.deadline)
        + field_bool("interruptible", r.interruptible)
    )


def encode_resources(r: Resources) -> String:
    return (
        field("cpu", r.cpu)
        + field("memory", r.memory)
        + field_int("gpu", r.gpu)
        + field("gpu_type", r.gpu_type)
    )
