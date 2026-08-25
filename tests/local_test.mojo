"""Local test suite for the flyte Mojo SDK (tests/local_test.mojo).

Run:
    mojo run tests/local_test.mojo
"""
from std.collections import List
from std.os import setenv

from flyte import *
from flyte._bridge import journal_lookup
from flyte._spec import encode_cache, encode_reliability, encode_resources, encode_reuse, encode_secrets
from flyte._state import state
from flyte._wire import from_wire, supported_on_wire, to_wire


def _check(ok: Bool, label: String) raises:
    state().test_check(ok, label)


# --- fixtures ---------------------------------------------------------------


def _hello(name: String) -> String:
    return "hello, " + name + "!"


def _add(a: Int, b: Int) -> Int:
    return a + b


def _ping() -> String:
    return "pong"


def _double(x: Int) -> Int:
    return x * 2


def _failing(x: Int) raises -> Int:
    if x < 0:
        raise Error("negative input")
    return x


def _ctx_probe() raises -> String:
    var c = ctx()
    return c.run + "|" + c.action + "|" + String(c.depth)


def _add_traced(a: Int, b: Int) raises -> Int:
    var d = double(a)
    return a + b + d - d


def _triple(x: Int) -> Int:
    return x * 3


def _grouped(n: Int) raises -> Int:
    """Two named regions, so the report has two levels to show."""
    var total: Int = 0
    with group("part-one"):
        total += triple(n)
    with group("part-two"):
        total += triple(n + 1)
    return total


def _group_failing(n: Int) raises -> Int:
    with group("doomed"):
        _ = failing(-1)
    return n


def _fan(n: Int) raises -> Int:
    """A task that fans out over a bound task — one child action per item."""
    var items = List[Int]()
    for i in range(n):
        items.append(i + 1)
    var out = map[f=triple, name="test.triple"](items)
    var total: Int = 0
    for v in out:
        total += v
    return total


comptime env = TaskEnvironment["test"]()
comptime hello = env.task[f=_hello, name="hello"]()
comptime add = env.task[f=_add, name="add"]()
comptime ping = env.task[f=_ping, name="ping"]()
comptime double = env.trace[f=_double, name="double"]()
comptime failing = env.task[f=_failing, name="failing"]()
comptime ctx_probe = env.task[f=_ctx_probe, name="ctx_probe"]()
comptime add_with_trace = env.task[f=_add_traced, name="add_traced"]()
comptime triple = env.task[f=_triple, name="triple"]()
comptime fan = env.task[f=_fan, name="fan"]()
comptime grouped = env.task[f=_grouped, name="grouped"]()
comptime group_failing = env.task[f=_group_failing, name="group_failing"]()

def main() raises:
    # ------------------------------------------------------------------
    print("== direct task call ==")
    _check(hello("world") == "hello, world!", "hello returns correct value")
    _check(add(2, 3) == 5, "add returns correct value")
    _check(ping() == "pong", "zero-arg task works")

    # ------------------------------------------------------------------
    print("== run: lifecycle ==")
    var r1 = run[f=hello, name="test.hello", run_name="test-run-1"]("flyte")
    _check(r1.name == "test-run-1", "run name respected")
    _check(r1.output == "hello, flyte!", "run output matches task output")
    _check(r1.phase == "SUCCEEDED", "run phase SUCCEEDED")
    _check(r1.url == "local://test-run-1", "run url is local://<name>")

    # ------------------------------------------------------------------
    print("== run: trace report ==")
    var report = r1.report()
    _check("test.hello(flyte)" in report, "report contains task call")
    _check("SUCCEEDED" in report, "report contains phase")

    # ------------------------------------------------------------------
    print("== multi-arg task ==")
    var r2 = run[f=add, name="test.add"](10, 20)
    _check(r2.output == 30, "two-arg task output")
    _check("test.add(10, 20) -> 30" in r2.report(), "two-arg event recorded")

    # ------------------------------------------------------------------
    print("== nesting: trace inside task ==")
    var r3 = run[f=add_with_trace, name="test.add_traced"](10, 20)
    var r3report = r3.report()
    _check("trace test.double" in r3report, "nested trace recorded")
    _check("\n    OK" in r3report, "nested trace indented (depth 1)")
    _check("task test.add_traced" in r3report, "parent task recorded")

    # ------------------------------------------------------------------
    print("== errors: failure recorded, error propagates ==")
    var caught = False
    try:
        var bad = run[f=failing, name="test.failing", run_name="test-run-bad"](-1)
        _check(False, "failing task should raise")
    except e:
        caught = True
    _check(caught, "error propagated to caller")

    # ------------------------------------------------------------------
    print("== ctx: run context inside a task ==")
    var r4 = run[f=ctx_probe, name="test.ctx_probe", run_name="test-run-ctx"]()
    _check(r4.output == "test-run-ctx|test.ctx_probe|1", "ctx sees run name, action, depth")

    # ------------------------------------------------------------------
    print("== map: fan-out runs every item and records every call ==")
    var r5 = run[f=fan, name="test.fan"](3)
    _check(r5.output == 18, "map applied the task to each item (3+6+9)")
    var fanreport = r5.report()
    _check("test.triple(1) -> 3" in fanreport, "first fanned-out call recorded")
    _check("test.triple(3) -> 9" in fanreport, "last fanned-out call recorded")

    # ------------------------------------------------------------------
    print("== group: naming a region of a workflow ==")
    var r6 = run[f=grouped, name="test.grouped"](2)
    _check(r6.output == 15, "the grouped body still computes (6+9)")
    var greport = r6.report()
    _check("-- group part-one" in greport, "the first group is recorded")
    _check("-- group part-two" in greport, "the second group is recorded")
    _check("\n      OK  task test.triple(2)" in greport, "work nests inside its group")
    _check(greport.find("part-one") < greport.find("part-two"), "groups keep their order")

    var group_raised = False
    try:
        var bad2 = run[f=group_failing, name="test.group_failing"](1)
    except e:
        group_raised = True
    _check(group_raised, "an error inside a group still propagates")
    # the group must have been left, or the next run would nest under it
    var r7 = run[f=hello, name="test.hello", run_name="after-group"]("x")
    _check("\n  OK  task test.hello" in r7.report(), "leaving a group unwinds the stack")

    # ------------------------------------------------------------------
    print("== spec: configuration folded in at compile time ==")
    comptime empty: String = encode_resources(Resources())
    comptime cpu_only: String = encode_resources(Resources(cpu="2"))
    comptime full: String = encode_resources(
        Resources(cpu="2", memory="4Gi", gpu=1, gpu_type="A100")
    )
    _check(empty == "", "an unset Resources encodes to nothing")
    _check(cpu_only == "cpu=2\t", "a set field encodes as key=value")
    _check(
        full == "cpu=2\tmemory=4Gi\tgpu=1\tgpu_type=A100\t",
        "every set field is encoded, in order",
    )
    comptime merged: String = cpu_only + encode_resources(Resources(cpu="8"))
    _check(merged == "cpu=2\tcpu=8\t", "an override is appended, for the reader to resolve")

    comptime steady: String = encode_reliability(Reliability())
    comptime flaky: String = encode_reliability(
        Reliability(retries=3, timeout=60, interruptible=True)
    )
    _check(steady == "", "reliability is inherited unless asked for")
    _check(
        flaky == "retries=3\ttimeout_runtime=60\tinterruptible=true\t",
        "a bare retries and timeout encode as a count and a max_runtime",
    )
    _check(
        encode_reliability(Reliability(interruptible=False)) == "",
        "False means inherit, not force-off",
    )
    comptime paced: String = encode_reliability(
        Reliability(
            retries=RetryStrategy(count=5, backoff=Backoff(base=10, factor=2.0, cap=300))
        )
    )
    _check(
        paced == "retries=5\tbackoff_base=10\tbackoff_factor=2.0\tbackoff_cap=300\t",
        "a RetryStrategy carries its Backoff",
    )
    comptime bounded: String = encode_reliability(
        Reliability(
            timeout=Timeout(max_runtime=1800, max_queued_time=900, deadline=7200)
        )
    )
    _check(
        bounded == "timeout_runtime=1800\ttimeout_queued=900\ttimeout_deadline=7200\t",
        "a Timeout encodes its three bounds",
    )

    comptime no_reuse: String = encode_reuse(Reuse())
    comptime warm: String = encode_reuse(Reuse(replicas=2, idle_ttl=60, scope="run"))
    _check(no_reuse == "", "one pod per action unless reuse is asked for")
    _check(
        warm == "reuse_replicas=2\treuse_idle_ttl=60\treuse_scope=run\t",
        "a reuse policy encodes its replicas, ttl and scope",
    )

    comptime no_secrets: String = encode_secrets(Secrets())
    comptime two: String = encode_secrets(Secrets("A, B=BEE", group="team"))
    _check(no_secrets == "", "no secrets encodes to nothing")
    _check(two == "secrets=A, B=BEE\tsecret_group=team\t", "keys and group encode together")

    comptime no_cache: String = encode_cache(Cache())
    comptime auto_cache: String = encode_cache(Cache("auto"))
    comptime pinned: String = encode_cache(Cache("override", version="v2", salt="s"))
    _check(no_cache == "", "caching is off unless asked for")
    _check(auto_cache == "cache=auto\t", "a bare behavior encodes on its own")
    _check(
        pinned == "cache=override\tcache_version=v2\tcache_salt=s\t",
        "a pinned cache carries its version and salt",
    )

    # ------------------------------------------------------------------
    print("== journal: results a worker should not recompute ==")
    _ = setenv("FLYTE_MOJO_JOURNAL", "test.x\t99\t7\ntest.y\tab\tc")
    var hit = journal_lookup("test.x", ["7"])
    _check(hit.found and hit.value == "99", "a recorded call is found by fqn and args")
    _check(not journal_lookup("test.x", ["8"]).found, "different args are a miss")
    _check(not journal_lookup("test.z", ["7"]).found, "a different fqn is a miss")
    _check(not journal_lookup("test.x", ["7", "7"]).found, "a different arity is a miss")
    _check(journal_lookup("test.y", ["c"]).value == "ab", "a later record is reachable")
    _ = setenv("FLYTE_MOJO_JOURNAL", "test.esc\ta\\tb\tk")
    _check(journal_lookup("test.esc", ["k"]).value == "a\tb", "escaped values round-trip")
    _ = setenv("FLYTE_MOJO_JOURNAL", "")
    _check(not journal_lookup("test.x", ["7"]).found, "an empty journal is a miss")

    # ------------------------------------------------------------------
    print("== wire: values that can cross to a worker and back ==")
    _check(to_wire(Int(42)) == "42", "Int serializes to its decimal form")
    _check(from_wire[Int]("42") == 42, "Int round-trips")
    _check(from_wire[String]("hi") == "hi", "String round-trips")
    _check(from_wire[Float64]("1.5") == 1.5, "Float64 round-trips")
    _check(from_wire[Bool]("True"), "Bool round-trips")
    _check(supported_on_wire[Int](), "Int is wire-supported")

    # ------------------------------------------------------------------
    print("== mode: local execution is the default ==")
    _check(not is_worker(), "a driver process is not a worker")
    _check(mode() == MODE_LOCAL, "mode is local until a config says otherwise")

    # ------------------------------------------------------------------
    # A fixture config, not ~/.flyte/config.yaml: these assertions must hold
    # on any machine, whatever cluster the developer happens to be pointed at.
    print("== config: init_from_config ==")
    comptime FIXTURE = "tests/fixture_config.yaml"
    var cfg = init_from_config(FIXTURE, mode="local")
    _check(cfg.endpoint == "dns:///fixture.example.com", "config endpoint parsed")
    _check(cfg.org == "fixture-org", "config org parsed")
    _check(cfg.project == "fixture-project", "config project parsed")
    _check(cfg.domain == "development", "config domain parsed")
    _check(cfg.image_builder == "remote", "config image builder parsed")
    _check(cfg.mode == MODE_LOCAL, "mode='local' overrides a cluster config")
    _check(mode() == MODE_LOCAL, "the session records the resolved mode")

    # ------------------------------------------------------------------
    print("== config: a cluster endpoint selects remote execution ==")
    var auto = init_from_config(FIXTURE)
    _check(auto.mode == MODE_REMOTE, "mode='auto' + endpoint -> remote")
    _check(mode() == MODE_REMOTE, "session mode follows the config")

    # runs must stay in-process for the rest of the suite
    var back = init_from_config(FIXTURE, mode="local")
    _check(back.mode == MODE_LOCAL, "mode is switchable back to local")

    # ------------------------------------------------------------------
    print("== config: bad input is rejected ==")
    var rejected = False
    try:
        var bad = init_from_config(FIXTURE, mode="cluster")
    except e:
        rejected = True
    _check(rejected, "unknown mode raises")

    var missing = False
    try:
        var gone = init_from_config("tests/no_such_config.yaml")
    except e:
        missing = True
    _check(missing, "an explicit config path that does not exist raises")

    # ------------------------------------------------------------------
    var tally = state().test_tally()
    var passed: Int = Int(String(tally["passed"]))
    var failed: Int = Int(String(tally["failed"]))
    print()
    print(String(passed) + " passed, " + String(failed) + " failed")
    if failed > 0:
        raise Error("test failures")
