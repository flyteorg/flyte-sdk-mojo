# flyte-mojo-sdk

Flyte 2 SDK for Mojo — define Flyte tasks and traces as plain Mojo functions,
run them locally in-process, and launch them on a live Flyte cluster.

```
hello.mojo
    └─ import flyte            (Mojo package)
         ├─ task/trace binding at comptime (compile-time reflection)
         ├─ local execution: in-process, structured trace, readable report
         └─ remote execution: drives the Python flyte control plane
              └─ _flyte_mojo_state.py (Mojo↔Python bridge, state + config + remote)
                   └─ Python flyte SDK (auth, bundling, cluster scheduling)
                        └─ Flyte 2 cluster
```

## Status

| Area | Status |
|------|--------|
| Local task execution (0–3 args) | ✅ working |
| Trace binding (tasks + traces, nesting) | ✅ working |
| Structured trace + readable report | ✅ working |
| `ctx()` (run name, action, depth) | ✅ working |
| Error recording + propagation | ✅ working |
| Config loading (`~/.flyte/config.yaml`) | ✅ working |
| Live cluster runs (auth + scheduling + outputs) | ✅ working |
| Multi-type / complex return values | ✅ String/Int (v1); extension via Writable |
| Native Mojo tasks on cluster (Tier 3) | ⏳ roadmap (gRPC action protocol) |

## Setup

```sh
uv venv
uv pip install mojo==1.0.0 flyte
source .venv/bin/activate
```

- Mojo 1.0.0 (via the `mojo` package; installs `mojo` CLI into the venv)
- Python `flyte` SDK 2.x (control plane for cluster runs)
- For cluster runs: `~/.flyte/config.yaml` (as produced by `flyte init`)

## Quick start

### hello.mojo — the minimal task

```mojo
from flyte import *

def _hello(name: String) -> String:
    return "hello, " + name + "!"

comptime env = TaskEnvironment["demo"]()
comptime hello = env.task[f=_hello, name="hello"]()

def main() raises:
    print(hello("flyte2"))
    var run = run[f=hello, name="demo.hello"]("flyte2")
    print(run.name, run.url, run.output)
    print(run.report())
```

```sh
$ mojo run hello.mojo
hello, flyte2!
run name: run-d524d1a2a1
run url: local://run-d524d1a2a1
run output: hello, flyte2!

Run run-d524d1a2a1  [SUCCEEDED]
  url:   local://run-d524d1a2a1
  fqn:   demo.hello   mode: local
  OK  task demo.hello(flyte2) -> hello, flyte2!  [0.0ms]
output: hello, flyte2!
```

### agent.mojo — task + trace composition

```mojo
from flyte import *

def _double(x: Int) -> Int:
    return x * 2

def _summarize(q: String) raises -> String:
    var d = double(21)          # bound trace: recorded as a nested event
    return "summary(" + q + ") doubled=" + String(d)

comptime env = TaskEnvironment["agent"]()
comptime double = env.trace[f=_double, name="double"]()
comptime summarize = env.task[f=_summarize, name="summarize"]()

def main() raises:
    var run = run[f=summarize, name="agent.summarize"]("hello")
    print(run.report())
```

```
Run run-b944fe06d1  [SUCCEEDED]
  url:   local://run-b944fe06d1
  fqn:   agent.summarize   mode: local
  OK  task agent.summarize(hello) -> summary(hello) doubled=42  [0.0ms]
    OK  trace agent.double(21) -> 42  [0.0ms]
output: summary(hello) doubled=42
```

### remote_hello.mojo — live cluster run

The task is defined in a Python file (cluster actions run Python); the Mojo
SDK drives the Python `flyte` control plane — auth, bundling, scheduling:

```mojo
from std.collections import List
from flyte import *

def main() raises:
    var cfg = init_from_config()
    print("cluster:", cfg.endpoint, cfg.org, cfg.project, cfg.domain)
    var args: List[String] = ["flyte2"]
    var run = remote_run(file="remote_hello_task.py", task="hello", args=args)
    print(run.name, run.url, run.phase)
    print("output:", run.output)
```

```
$ mojo run remote_hello.mojo
cluster: dns:///demo.hosted.unionai.cloud demo flytesnacks development
[flyte] OK Run 'ug2frlf8jx5gs487hkfq' completed successfully
run name: ug2frlf8jx5gs487hkfq
run url: https://demo.hosted.unionai.cloud/v2/domain/development/project/flytesnacks/runs/ug2frlf8jx5gs487hkfq
phase: SUCCEEDED
output: hello, flyte2! doubled(21)=42
```

## API

| API | Purpose |
|-----|---------|
| `TaskEnvironment[env_name]()` | compile-time environment (bakes `env` into FQNs) |
| `env.task[f=fn, name="n"]()` | bind a Mojo function as a Flyte task (arity 0–3) |
| `env.trace[f=fn, name="n"]()` | bind a Mojo function as a trace (arity 0–3) |
| `run[f=bound, name="fqn", run_name=...](args)` | start a local run, execute, return `Run` |
| `Run[R].name/.url/.phase/.output` | run identity + result |
| `Run[R].report()` | readable trace of the run |
| `ctx()` | current run context inside a task/trace (run, action, depth) |
| `Config` / `init_from_config()` | load `~/.flyte/config.yaml` |
| `remote_run(file, task, args)` | run a Python task file on the live cluster |

### Conventions

- **Comptime binding**: binding is a compile-time value — no decorators, no
  import-time side effects. Functions may be declared in any order relative
  to their binding (forward references are fine).
- **Naming**: the bound name is the Flyte action name; FQN =
  `{env}.{name}`. The `name=` argument is the comptime source of truth.
- **Errors**: use Mojo `Error` (`raise Error("...")`) inside tasks; failures
  are recorded in the trace and propagate to the caller.
- **State**: all mutable state lives in the Python bridge module
  (`_flyte_mojo_state.py`) — Mojo modules have no globals.

## Layout

```
flyte/                  # Mojo SDK package
  __init__.mojo         # public API
  _core.mojo            # arity 0–3 task/trace/run wrappers + factories
  _env.mojo             # TaskEnvironment + Resources (binding API)
  _run.mojo             # Run[R] result struct
  _ctx.mojo             # Ctx + ctx()
  _config.mojo          # Config + init_from_config()
  _remote.mojo          # remote_run() (live cluster)
  _state.mojo           # bridge accessor to the Python state module
_flyte_mojo_state.py    # Python bridge: state, config, test helpers, remote
hello.mojo              # minimal task example
agent.mojo              # task + trace composition example
remote_hello.mojo       # live cluster example (driver)
remote_hello_task.py    # task definition executed on the cluster
tests/local_test.mojo   # test suite (20 checks)
```

## Testing

```sh
mojo run tests/local_test.mojo   # 20 passed, 0 failed
```

## Design notes

- **Candidate A (comptime binding)** from the design doc: binding is a
  comptime value; the wrapper is a thin function value that records the
  action event in the bridge, calls the user function, and records the
  result — with zero runtime reflection.
- **Keyword comptime arguments**: `factory[f=fn, name="n"]()` (Mojo 1.0.0
  requires keyword form for comptime bindings of trait-constrained
  parameters).
- **Remote v1 = Tier 2**: Mojo drives the Python control plane. Tier 3
  (native Mojo gRPC action protocol, running *Mojo* tasks on the cluster)
  is the next milestone.
