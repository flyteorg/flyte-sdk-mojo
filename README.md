# flyte-mojo-sdk

Flyte 2 SDK for Mojo. Write a task as a plain Mojo function, bind it at
compile time, and run it. **Where it runs is a property of the config, not
of your code** — the same file runs in-process or natively on a cluster.

```mojo
# hello.mojo
from flyte import *

def _hello(name: String) -> String:
    return "hello, " + name + "!"

comptime env = TaskEnvironment["demo"]()
comptime hello = env.task[f=_hello, name="hello"]()

def main() raises:
    var cfg = init_from_config()                        # cluster config?
    var r = run[f=hello, name="demo.hello"]("flyte2")   # then run there
    print(r.output)
```

```sh
$ mojo run hello.mojo
mode: remote   cluster: dns:///demo.hosted.unionai.cloud
[flyte-mojo] compiling hello.mojo for linux/amd64 (a764ebfcbe82)...
[flyte-mojo] launching demo.hello on the cluster...
[flyte] OK Code bundle: 6 files, 2.10 MB (compressed 0.81 MB)
[flyte] OK Run 'uks6hfs5tkhl4c6nwm8b' completed successfully
run:    uks6hfs5tkhl4c6nwm8b
url:    https://demo.hosted.unionai.cloud/v2/domain/development/project/flytesnacks/runs/uks6hfs5tkhl4c6nwm8b
output: hello, flyte2!
```

No task file, no Python shim, no build step. The task body that ran on the
cluster is compiled Mojo. Call one task from another and it becomes a child
action; call a trace and it becomes a span — see
[Multi-action workflows](#multi-action-workflows).

## How one file runs in three places

A program written against this SDK plays one of three roles. It never
branches on them: `init_from_config()` and `run[...]` do.

| Role | When | What `run[...]` does |
|------|------|----------------------|
| **local** | no `~/.flyte/config.yaml` | executes in-process, records a trace |
| **driver** | the config names an endpoint | compiles *this file* for linux/amd64, ships it, waits |
| **worker** | `FLYTE_MOJO_ACTION` is set (inside the pod) | executes the named action, and asks the shim for any child actions and traces it hits |

```
mojo run hello.mojo                          cluster (linux/amd64)
─────────────────────                        ─────────────────────
init_from_config()  ── endpoint? ──▶ remote  ┌────────────────────────────┐
                                             │ action pod                 │
run[f=hello, ...]("flyte2")                  │ 1. shim execs the binary   │
    │                                        │    FLYTE_MOJO_ACTION=      │
    │  1. hash every .mojo input             │      demo.hello            │
    │  2. docker build (cached image)        │ 2. main() runs again, this │
    │     mojo build -O3  ─────────────────▶ │    time as a worker        │
    │  3. generate a one-task shim           │ 3. run[...] matches the    │
    │  4. flyte bundle + launch + wait  ◀────│    action, prints the      │
    ▼                                        │    result, exits           │
Run[B] — typed output, name, url             └────────────────────────────┘
```

The worker is the *same binary* as your program, so the task body is native
Mojo. The generated shim is the only Python in the pod: it sets
`FLYTE_MOJO_ACTION`, execs the binary, and reads the result off a marked
stdout line. Everything else the program prints becomes pod logs.

Builds are cached on the content of your program plus every `.mojo` file in
a subdirectory (i.e. the SDK). An unchanged program launches in ~5s; a
changed one recompiles in ~15s. The one-time builder image build is ~1 min.

## Multi-action workflows

One rule, the same one Flyte already uses:

- a **task** called from inside a task becomes a **child action** — its own pod,
  running this same binary
- a **trace** called from inside a task stays **in-process** and is recorded as a
  **span**
- `map[f=task, name=...](items)` fans out into **one child action per item**,
  launched together

So `pipeline.mojo` is one file, and this is the tree Flyte builds from it:

```
etl.pipeline                  root action
├─ etl.extract                child action
│   └─ etl_normalize          trace
├─ etl.score  x4              child actions, started within 40ms of each other
└─ etl.summarize              child action
    └─ etl_grade              trace
```

Nothing declares that shape. It falls out of what the Mojo code calls, so it can
depend on the data — `agent.mojo` decides how many `agent.search` actions to run
from the question it was given, and whether to run a second round from what the
first one scored.

Traces arrive as real `ACTION_TYPE_TRACE` nodes parented to the action that ran
them, with real timings: the shim holds a `flyte.trace` context open for exactly
as long as the Mojo code spends inside the trace.

### Grouping

A group names a *region* of a workflow rather than a single call, so it is a
`with` block:

```mojo
with group("scoring"):
    var scores = map[f=score, name="etl.score"](items)
    total = sum_of(scores)
    return summarize(total, len(scores))
```

Everything launched inside lands under `scoring` in the UI; `etl.extract`, which
sits outside the block, stays ungrouped. Groups nest, and the block is left
cleanly even when something inside it raises. Locally the same block shows up as
a level in the run report:

```
OK  task etl.pipeline(4) -> scored 4 items, total=2166116814, grade=warm
  OK  task etl.extract(4) -> 1,8,15,22
    OK  trace etl.normalize(4) -> 1,8,15,22
  -- group scoring
    OK  task etl.score(1) -> 258475185
    ...
```

Grouping is entirely opt-in — nothing groups your actions for you.

### Running the tree without a cluster

```sh
make simulate
```

`tests/simulate.py` speaks the same control protocol as the pod-side shim, but
runs each action as a local `mojo run` instead of a Flyte task. It prints the
tree Flyte would build — useful for getting a workflow right before paying for
a cluster round trip:

```
etl.pipeline(4)
  etl.extract(4)
    ~etl.normalize(4)
  etl.score(1)
  etl.score(8)
  etl.score(15)
  etl.score(22)
  etl.summarize(2166116814, 4)
    ~etl.grade(2166116814)

7 actions, 2 traces
output: scored 4 items, total=2166116814, grade=warm
```

### How a child action finds its work

A worker launched for a late action still starts at `main()`, so it replays the
program until it reaches that action. Replaying would mean redoing every earlier
task — so each child is handed a **journal** of the results already computed for
this run, and reads them back instead of re-executing:

```
summarize inputs:
  args:    ['2166116814', '4']
  journal: ['etl.extract\t1,8,15,22\t4',
            'etl.score\t258475185\t1', ... ]
```

That keeps upstream work — and upstream side effects — to exactly once per run.

## Setup

```sh
uv venv
uv pip install mojo==1.0.0 flyte
source .venv/bin/activate
```

- Mojo 1.0.0, Python `flyte` SDK 2.x
- For cluster runs: `~/.flyte/config.yaml` (as produced by `flyte init`) and
  a running Docker daemon (to cross-compile the linux/amd64 task binary)

## Examples

| File | Shows |
|------|-------|
| `hello.mojo` | the minimal task — one function, one run |
| `fib.mojo` | native-speed compute, typed `Int` in and out, and the failure path |
| `pipeline.mojo` | a multi-action workflow: extract → parallel fan-out → summarize, with traces |
| `agent.mojo` | a *data-dependent* tree: branch on a result, and a child action with children of its own |
| `python_task.mojo` + `.py` | the escape hatch: drive an *existing Python* task from Mojo |

```sh
make hello        # or fib / pipeline / agent / python-task
make fib-fail     # a Mojo error from inside the pod, back in your terminal
make simulate     # the whole multi-action tree locally, no cluster
make local        # run the examples in-process, ignoring any cluster config
make test         # 53 local checks + 25 worker/protocol checks
```

`make fib-fail` shows the whole failure path — Mojo `raise` in the pod →
non-zero exit → shim `RuntimeError` → action `FAILED` →
`ActionDetails.error_info` → a Mojo `Error` in your terminal:

```
remote run uln4wkwlt89745fwxz2x failed (FAILED):
  mojo action demo.fib failed (exit 1): n out of range (0..91): 200
```

## API

| API | Purpose |
|-----|---------|
| `TaskEnvironment[env_name]()` | compile-time environment (bakes `env` into FQNs) |
| `env.task[f=fn, name="n"]()` | bind a Mojo function as a Flyte task (arity 0–3) |
| `env.trace[f=fn, name="n"]()` | bind a Mojo function as a trace (arity 0–3) |
| `run[f=bound, name="fqn", run_name=...](args)` | run it — locally or on the cluster |
| `map[f=bound, name="fqn"](items)` | fan out: one child action per item, in parallel |
| `with group("name"):` | name a region of the workflow (nests; opt-in) |
| `Run[R].name/.url/.phase/.output` | run identity + typed result |
| `Run[R].report()` | readable trace of the run (local and remote) |
| `ctx()` | current run context inside a task/trace |
| `init_from_config(path="", mode="auto")` | load config **and** select the mode |
| `mode()` / `is_worker()` | the current role of this process |
| `remote_run(file, task, args)` | escape hatch: run a task from a Python file |

### `init_from_config`

```mojo
var cfg = init_from_config()                  # endpoint in config -> remote
var cfg = init_from_config(mode="local")      # force in-process
var cfg = init_from_config("other.yaml")      # a specific config file
```

A missing *default* config is not an error — it means local mode. A missing
*explicit* path is an error. `cfg.mode` is `"local"`, `"remote"` or
`"worker"`.

### Conventions

- **Comptime binding**: binding is a compile-time value — no decorators, no
  import-time side effects. Functions may be declared in any order relative
  to their binding.
- **Naming**: the bound name is the Flyte action name; FQN = `{env}.{name}`.
- **Errors**: `raise Error("...")` inside a task; failures are recorded in
  the trace and propagate to the caller, locally and remotely.
- **State**: all driver-side mutable state lives in the Python bridge
  (`_flyte_mojo_state.py`) — Mojo modules have no globals. The *worker* path
  deliberately never touches it, so a task pod needs no Python interpreter
  of its own.

### Where the SDK lives

Everything the SDK needs is inside `flyte/`, including its two Python halves —
the repo root is yours. `flyte/` deliberately has **no `__init__.py`**: adding
one would make it a regular Python package on `sys.path` and shadow the
installed Flyte SDK. `flyte/_state.mojo` therefore finds the bridge by walking
up from your program looking for `flyte/_flyte_mojo_state.py`, and imports it
under its own name. Set `FLYTE_MOJO_SDK` to the package directory if you keep it
somewhere unusual.

## Limits worth knowing

These are real constraints of the current design, not TODO noise.

- **Values crossing an action boundary are scalars.** Arguments and results
  travel as strings, and only `String`, `Int`, `Float64` and `Bool` can be read
  back (`flyte/_wire.mojo`). Mojo has no general "parse me from a string" trait
  to hook into, so a custom struct cannot round-trip yet. A task whose *result*
  is not wire-readable cannot be a child action.
- **A worker replays `main()` to reach its action.** The journal covers task
  results, so upstream *tasks* run once — but anything else on that path (plain
  Mojo code, traces, `print`) runs again in each pod. Keep `main()` and the code
  between task calls free of side effects.
- **A recursive task does not fan out.** A task that calls itself runs
  in-process; only calls to a *different* task become child actions.
- **The journal rides on an environment variable**, so a run with thousands of
  child results will hit the OS argument-size limit before Flyte's.
- **`TaskEnvironment` image and resources are descriptive.** They are recorded on
  the environment but are not yet plumbed into the generated shim, so every
  action gets Flyte's default image and resources — including a fanned-out task
  that might want a GPU.
- **One pod per action, and each pod re-execs the binary.** Startup dominates
  anything short: in `pipeline.mojo` the four `etl.score` actions spend ~3s each
  on pod overhead around ~25ms of actual Mojo. Fan out over real work, not
  microseconds of it.
- **linux/amd64 only**, and Docker is required to produce it.

## Layout

```
flyte/                  # Mojo SDK package
  __init__.mojo         # public API
  _mode.mojo            # role detection (local / driver / worker) — no Python
  _bridge.mojo          # worker<->shim control protocol + the replay journal
  _map.mojo             # map[...]: parallel fan-out
  _wire.mojo            # string <-> typed values for the remote boundary
  _core.mojo            # arity 0-3 task/trace/run wrappers + factories
  _env.mojo             # TaskEnvironment + Resources (binding API)
  _config.mojo          # Config + init_from_config() + mode()
  _remote.mojo          # remote dispatch + the Python-task escape hatch
  _group.mojo           # group(): `with` blocks that name a region
  _run.mojo             # Run[R] result struct
  _ctx.mojo             # Ctx + ctx()
  _state.mojo           # finds and imports the Python bridge below
  _flyte_mojo_state.py  # driver side: state, config, cross-compile, launch
  flyte_mojo_shim.py    # pod side: drives the binary, services its requests
hello.mojo              # minimal task
agent.mojo              # data-dependent tree: branching + a grandchild action
fib.mojo                # native compute + failure path
pipeline.mojo           # multi-action workflow: fan-out + traces
python_task.mojo/.py    # escape hatch: an existing Python task
tests/local_test.mojo   # 53 checks
tests/worker_checks.sh  # 25 worker/protocol checks (no cluster needed)
tests/simulate.py       # runs a multi-action tree locally, one process per action
tests/worker_flow.mojo  # fixture program for the worker-role checks
tests/fixture_config.yaml  # fixed config so the suite is machine-independent
_flyte_mojo/            # generated: builder Dockerfile + cached builds (gitignored)
```
