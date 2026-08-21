"""Local test suite for the flyte Mojo SDK (tests/local_test.mojo).

Run:
    mojo run tests/local_test.mojo
"""
from flyte import *
from flyte._state import state


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


comptime env = TaskEnvironment["test"]()
comptime hello = env.task[f=_hello, name="hello"]()
comptime add = env.task[f=_add, name="add"]()
comptime ping = env.task[f=_ping, name="ping"]()
comptime double = env.trace[f=_double, name="double"]()
comptime failing = env.task[f=_failing, name="failing"]()
comptime ctx_probe = env.task[f=_ctx_probe, name="ctx_probe"]()
comptime add_with_trace = env.task[f=_add_traced, name="add_traced"]()

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
    print("== config: init_from_config ==")
    var cfg = init_from_config()
    _check(cfg.endpoint != "", "config endpoint parsed")
    _check(cfg.org == "demo", "config org parsed")
    _check(cfg.project == "flytesnacks", "config project parsed")
    _check(cfg.domain == "development", "config domain parsed")

    # ------------------------------------------------------------------
    var tally = state().test_tally()
    var passed: Int = Int(String(tally["passed"]))
    var failed: Int = Int(String(tally["failed"]))
    print()
    print(String(passed) + " passed, " + String(failed) + " failed")
    if failed > 0:
        raise Error("test failures")
