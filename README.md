# flyte-mojo-sdk

Flyte 2 SDK for Mojo. Write a task as a plain Mojo function, bind it at
compile time, and run it. **Where it runs is a property of the config, not
of your code** — the same file runs in-process or natively on a cluster.

```mojo
# examples/hello.mojo
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
$ mojo run -I . examples/hello.mojo
mode: remote   cluster: dns:///demo.hosted.unionai.cloud
[flyte-mojo] compiling examples/hello.mojo for linux/amd64 (83d2a38209cf)...
[flyte-mojo] launching demo.hello on the cluster...
[flyte] OK Code bundle: 6 files, 2.10 MB (compressed 0.81 MB)
[flyte] OK Run 'uks6hfs5tkhl4c6nwm8b' completed successfully
run:    uks6hfs5tkhl4c6nwm8b
url:    https://demo.hosted.unionai.cloud/v2/domain/development/project/flytesnacks/runs/uks6hfs5tkhl4c6nwm8b
output: hello, flyte2!
```

No task file, no Python shim, no build step. The task body that ran on the
cluster is compiled Mojo, in a binary that does not link Python at all — see
[What runs in Mojo, what runs in Python](#what-runs-in-mojo-what-runs-in-python).
Call one task from another and it becomes a child action; call a trace and it
becomes a span — see [Multi-action workflows](#multi-action-workflows).

## How one file runs in three places

A program written against this SDK plays one of three roles. It never
branches on them: `init_from_config()` and `run[...]` do.

| Role | When | What `run[...]` does |
|------|------|----------------------|
| **local** | no `~/.flyte/config.yaml` | executes in-process, records a trace |
| **driver** | the config names an endpoint | compiles *this file* for linux/amd64, ships it, waits |
| **worker** | `FLYTE_MOJO_ACTION` is set (inside the pod) | executes the named action, and asks the shim for any child actions and traces it hits |

```
mojo run -I . examples/hello.mojo            cluster (linux/amd64)
─────────────────────────────────           ─────────────────────
init_from_config()  ── endpoint? ──▶ remote  ┌────────────────────────────┐
                                             │ action pod                 │
run[f=hello, ...]("flyte2")                  │ 1. shim execs the binary   │
    │                                        │    FLYTE_MOJO_ACTION=      │
    │  1. hash every .mojo input             │      demo.hello            │
    │  2. docker build (cached image)        │ 2. main() runs again, this │
    │     mojo build -O3  ─────────────────▶ │    time as a worker        │
    │  3. generate the action shim           │ 3. run[...] matches the    │
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

## What runs in Mojo, what runs in Python

Your task body is always native Mojo. Python is the *control plane* on your
machine and a thin supervisor in the pod — it is never in the compute path.

| | Mojo | Python |
|---|---|---|
| **your machine** | your program; binding, local execution, the local trace | reads the config, cross-compiles, bundles, authenticates, launches, waits |
| **the action pod** | the task body, its traces, and all of its control flow | receives the action, execs the binary, turns its requests into child actions and trace spans |

The pod half is worth being concrete about: the compiled binary does not link
Python at all.

```sh
$ ldd task_binary          # inside the linux/amd64 image, no LD_LIBRARY_PATH set
    libKGENCompilerRTShared.so => not found     # the Mojo runtime, bundled beside it
    libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6
    /lib64/ld-linux-x86-64.so.2
```

libc and the Mojo runtime, and nothing else. Mojo loads a Python interpreter on
demand, at the first interop call — and a worker never makes one.

There is still a Python process in the pod — the generated shim is a Flyte task,
and Flyte schedules Python — but it only supervises. It execs the binary, reads
control lines off its stdout, and calls back into the Flyte SDK for the things
only the control plane can do: launching a child action, opening a
`flyte.trace` span, entering a `flyte.group`. Between those calls it is
blocked, and your Mojo code is what is running.

### Inside the SDK

Everything a worker relies on is Python-free, and that is deliberate rather
than incidental: a task pod is never one missing interpreter away from failing.
The modules that do reach Python are the ones only a driver runs.

| Module | Python? | |
|---|---|---|
| `_mode.mojo` | no | which role this process plays — `getenv`/`setenv` only |
| `_wire.mojo` | no | `String`↔typed values, resolved at compile time |
| `_bridge.mojo` | no | the control protocol and journal — stdout/stdin only |
| `_env.mojo` | no | `TaskEnvironment` — comptime binding, no calls of its own |
| `_core.mojo` | worker path: **no** | task/trace/run wrappers |
| `_map.mojo` | worker path: **no** | fan-out; the remote path is a protocol message |
| `_state.mojo` | yes | finds and imports the Python bridge |
| `_config.mojo` | yes | reads `~/.flyte/config.yaml` |
| `_ctx.mojo`, `_run.mojo`, `_group.mojo` | driver/local only | bookkeeping; each short-circuits in a worker |
| `_remote.mojo` | yes | hands a launch to the Python bridge |

On the Python side, `flyte/_flyte_mojo_state.py` runs on your machine and
`flyte/flyte_mojo_shim.py` runs in the pod. Only the latter is copied into the
code bundle.

### Why Python at all

Three reasons, none of them "Mojo can't":

1. **Flyte's action worker runs Python.** A pod is handed a Python task to
   import and call. There is no Mojo action protocol to register against, so
   something Python-shaped has to *be* the task and hand off from there.
2. **Mojo has no module-level mutable state.** The local trace — runs, events,
   nesting — needs somewhere to live for the length of a process, so it lives
   in a Python module the Mojo side talks to over a flat, scalars-only API.
3. **The control plane already exists.** PKCE auth, image resolution, code
   bundling, gRPC to the cluster, run polling. Reimplementing that in Mojo
   would be a large amount of work for an identical result.

Reason 2 is the one that could go away on its own as Mojo grows globals.
Reason 1 is the real milestone: a native Mojo action worker speaking Flyte's
gRPC protocol would remove Python from the pod entirely, and the binary already
being interpreter-free is most of the way there. Reason 3 will likely stay
true, and that is fine — it is a control plane, not a hot loop.

Local execution needs a Python interpreter but *not* the Flyte SDK: the bridge
imports `flyte` lazily, only on the paths that talk to a cluster.

## Multi-action workflows

One rule, the same one Flyte already uses:

- a **task** called from inside a task becomes a **child action** — its own pod,
  running this same binary
- a **trace** called from inside a task stays **in-process** and is recorded as a
  **span**
- `map[f=task, name=...](items)` fans out into **one child action per item**,
  launched together

So `examples/pipeline.mojo` is one file, and this is the tree Flyte builds from it:

```
etl.pipeline                  root action
├─ etl.extract                child action
│   └─ etl_normalize          trace
└─ scoring                    a group the code opened
    ├─ etl.score  x4          child actions, started within 40ms of each other
    └─ etl.summarize          child action
        └─ etl_grade          trace
```

Nothing declares that shape. It falls out of what the Mojo code calls, so it can
depend on the data — `examples/agent.mojo` decides how many `agent.search` actions to run
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

### Configuring an action

How much CPU an action gets, and everything like it, is a *compile-time
parameter* — binding happens at compile time, so a runtime field could never
reach it:

```mojo
comptime env = TaskEnvironment["etl", resources=Resources(cpu="1", memory="1Gi")]()

comptime score = env.task[f=_score, name="score"]()

with group("scoring"):
    var scores = env.map[
        f=score, name="etl.score", resources_override=Resources(cpu="2", memory="2Gi")
    ](items)
```

The environment sets the default and any call site can override it. On the
cluster that comes out as:

```
etl.pipeline     CPU 1 MEMORY 1Gi
etl.extract      CPU 1 MEMORY 1Gi
etl.score        CPU 2 MEMORY 2Gi     x4
etl.summarize    CPU 1 MEMORY 1Gi
```

The configuration is folded into one string at bind time and travels *with*
the action — on the launch for a root action, in the `CALL` request for a
child. Nothing is registered and nothing is parsed out of your source, so a
task's configuration cannot drift from the task.

**The free `run[...]` and `map[...]` carry no configuration.** They have no
environment to read it from, so anything you declare is silently ignored —
use `env.run` and `env.map` whenever an action needs configuring.

Three call sites take an override, and which one you want depends on what is
being launched:

| | configures |
|---|---|
| `env.task[..., resources_override=...]` | that task, when another task calls it |
| `env.map[..., resources_override=...]` | the children of that fan-out |
| `env.run[..., resources_override=...]` | the root action of that run |

`env.run` and `env.map` exist because the free `run[...]` and `map[...]` cannot
see the configuration: a root action is launched before its body ever runs, and
a fan-out is handed a bound function value whose parameters Mojo cannot inspect.
Declaring it at the launching call site is the honest version of that
constraint — and it means a fan-out's configuration sits next to the fan-out.

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
  [scoring]
    etl.score(1)
    etl.score(8)
    etl.score(15)
    etl.score(22)
    etl.summarize(2166116814, 4)
      ~etl.grade(2166116814)

7 actions, 2 traces, 1 groups
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

Mojo resolves packages relative to the file being compiled, so a program in
`examples/` needs the repo root on the import path. Run from the root with
`-I .`:

```sh
mojo run -I . examples/hello.mojo
```

Every `make` target already does this. A program sitting *beside* `flyte/`
needs no flag at all.

## Examples

| File | Shows |
|------|-------|
| `examples/hello.mojo` | the minimal task — one function, one run |
| `examples/fib.mojo` | native-speed compute, typed `Int` in and out, and the failure path |
| `examples/pipeline.mojo` | a multi-action workflow: extract → parallel fan-out → summarize, with traces |
| `examples/agent.mojo` | a *data-dependent* tree: branch on a result, and a child action with children of its own |
| `examples/inspect.mojo` | the control plane: what ran, how it went, why it failed |
| `examples/python_task.mojo` + `.py` | the escape hatch: drive an *existing Python* task from Mojo |

```sh
make hello        # or fib / pipeline / agent / python-task
make inspect      # recent runs, and the last failure's logs
make fib-fail     # a Mojo error from inside the pod, back in your terminal
make resume       # a task that fails once and resumes from its checkpoint
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
| `Resources(cpu=, memory=, gpu=, gpu_type=)` | what an action needs; empty fields inherit |
| `env.task[..., resources_override=...]` | configure one task |
| `env.map[...]` / `env.run[...]` | as `map` / `run`, carrying the environment's configuration |
| `with group("name"):` | name a region of the workflow (nests; opt-in) |
| `checkpoint_save(text)` / `checkpoint_load()` | state that survives a failed attempt |
| `Run[R].name/.url/.phase/.output` | run identity + typed result |
| `Run[R].report()` | readable trace of the run (local and remote) |
| `ctx()` | current run context inside a task/trace |
| `init_from_config(path="", mode="auto")` | load config **and** select the mode |
| `mode()` / `is_worker()` | the current role of this process |
| `runs(limit=)` / `status(name)` | what the cluster has run, and how it went |
| `abort(name)` / `rerun(name)` | stop a run, or run it again with the same inputs |
| `logs(name, lines=)` | the tail of a run's logs |
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
- **State**: all driver-side mutable state lives in the Python bridge, because
  Mojo modules have no globals. The worker path never touches it — see
  [What runs in Mojo, what runs in Python](#what-runs-in-mojo-what-runs-in-python).

### Where the SDK lives

Everything the SDK needs is inside `flyte/`, including its two Python halves.
Your code lives in `examples/`, and the repo root holds nothing but the
`Makefile` and this file. `flyte/` deliberately has **no `__init__.py`**: adding
one would make it a regular Python package on `sys.path` and shadow the
installed Flyte SDK. `flyte/_state.mojo` therefore finds the bridge by walking
up from your program looking for `flyte/_flyte_mojo_state.py`, and imports it
under its own name. Set `FLYTE_MOJO_SDK` to the package directory if you keep it
somewhere unusual.

That same directory is the *build root*: a remote run compiles your program
against the SDK and bundles both, so the two have to share a directory tree.
The build cache key is your program plus every `.mojo` file in the package —
editing one example never invalidates another's cached build.

## Compared with the Python SDK

This SDK covers Flyte's *execution model* — tasks, traces, child actions,
fan-out, grouping — so that native Mojo can be the thing a Flyte action runs.
It does not cover Flyte's platform surface. Most of what is missing is missing
because nobody has written it yet, not because Mojo is in the way.

### What works

| | Python | Mojo |
|---|---|---|
| define a task | `@env.task` | `env.task[f=_fn, name="n"]()` |
| define a trace | `@flyte.trace` | `env.trace[f=_fn, name="n"]()` |
| run one | `flyte.run(t, x)` | `run[f=t, name="fqn"](x)` |
| child actions | call a task inside a task | the same |
| fan-out | `flyte.map`, `asyncio.gather` | `map[f=t, name="fqn"](items)` |
| grouping | `with flyte.group("n"):` | `with group("n"):` |
| config and auth | `flyte.init_from_config()` | `init_from_config()` |
| run context | `flyte.ctx()` | `ctx()` |
| resources | `Resources(cpu=, memory=, gpu=)` | `TaskEnvironment["e", resources=Resources(...)]`, overridable per task, per fan-out and per run |
| caching | `cache="auto"` | `Cache("auto")`, or pinned with `version=` / `salt=` |
| reliability | `retries=RetryStrategy` / `int`, `timeout=Timeout` / `int`, `interruptible=` | `Reliability(retries=, timeout=, interruptible=)` — `retries` is a `RetryStrategy` (or a bare count), `timeout` a `Timeout` (or bare seconds, bounding one attempt's runtime) |
| secrets | `Secret(key=, as_env_var=)` | `Secrets("KEY, OTHER=ENV_NAME", group=)` |
| container reuse | `ReusePolicy` | `Reuse(replicas=, idle_ttl=, concurrency=, scope=)` — see the note below |
| images | `Image`, dependency specs | `TaskEnvironment["e", image="ghcr.io/..."]` — one per program |
| checkpoints | `flyte.Checkpoint` | `checkpoint_save(text)` / `checkpoint_load()` |
| control plane | `flyte.remote`: list, abort, logs, rerun | `runs()`, `status()`, `abort()`, `logs()`, `rerun()` |
| local execution | yes | yes, with a trace report |
| error propagation | exceptions | `Error`, with the Mojo message intact |

The container image is the exception to all of this: Flyte resolves it when
the *environment* is built, not when an action is launched, so it is declared
on `TaskEnvironment` and applies to every action of the program. That costs
nothing in practice — a program is one compiled binary in one code bundle, so
its actions were always going to share an image.

```mojo
comptime env = TaskEnvironment["demo", image="ghcr.io/flyteorg/flyte:py3.13-v2.6.3"]()
```

`Reuse` cannot be combined with `Resources` on the same action — a reusable
container already has the resources of its pool, and Flyte refuses the
override. The SDK raises with that explanation rather than letting Flyte's
error surface from inside the shim.

`Reuse` is also the one entry above not verified against a live cluster:
`demo.hosted.unionai.cloud` leaves an action with a reuse policy in
`WAITING_FOR_RESOURCES` indefinitely, so its container pool is evidently not
enabled there. The policy is asserted onto a real `TaskTemplate` by
`tests/override_checks.py`, but treat end-to-end behaviour as untested.

### What is missing

| Area | Python | Mojo today |
|---|---|---|
| **task I/O** | any typed value — `File`, `Dir`, `DataFrame`, dataclasses, Pydantic | `String`, `Int`, `Float64`, `Bool`; 0–3 positional arguments; one return value |
| **concurrency** | `asyncio.gather` over anything | `map` over one list; everything else is sequential |
| **apps and serving** | `flyte.serve`, FastAPI, vLLM | none |
| **deployment and scheduling** | `flyte deploy`, `Cron`, `Trigger` | run-only — nothing is registered, so nothing can be scheduled or called by anyone else |

These four are not a missing afternoon's work, and
[docs/design-notes.md](docs/design-notes.md) says what each would actually
take — including the Mojo limitations behind two of them, with the compiler
errors that establish them. The short version: files and directories are cheap
and worth doing next, deployment would let anything else call a Mojo task,
serving is the only one that would make this *faster* rather than more
complete, and heterogeneous concurrency needs Mojo function values to be
storable before it can be built without breaking local/remote parity.

### Reaching Python when you need it

`remote_run(file, task, args)` launches a task defined in a Python file, so
anything the Mojo side cannot express is still one call away —
`examples/python_task.mojo` does this. The trade is that the body is then
Python: you get the platform feature, not the compiled task.

### What you get that the Python SDK cannot give you

- **The task body is compiled native code.** No interpreter in the compute
  path, and the binary does not link Python at all.
- **One file is the driver and every task in it.** No task module, no shim, no
  separate build step.

## Limits worth knowing

Constraints of how this works, as opposed to features not yet written (those
are in the table above).

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
- **One pod per action, and each pod re-execs the binary.** Startup dominates
  anything short: in `examples/pipeline.mojo` the four `etl.score` actions spend
  ~3s each on pod overhead around ~25ms of actual Mojo. Fan out over real work,
  not microseconds of it.
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
  _env.mojo             # TaskEnvironment: names + all configuration (binding API)
  _spec.mojo            # the configuration itself: Resources, Cache, Reliability,
                        # Secrets, Reuse, and their wire encoding
  _config.mojo          # Config + init_from_config() + mode()
  _remote.mojo          # remote dispatch + the Python-task escape hatch
  _control.mojo         # control plane: runs(), status(), abort(), logs(), rerun()
  _group.mojo           # group(): `with` blocks that name a region
  _run.mojo             # Run[R] result struct
  _ctx.mojo             # Ctx + ctx()
  _state.mojo           # finds and imports the Python bridge below
  _flyte_mojo_state.py  # driver side: state, config, cross-compile, launch
  flyte_mojo_shim.py    # pod side: drives the binary, services its requests
examples/               # user-space code — nothing the SDK needs
  hello.mojo            # minimal task
  fib.mojo              # native compute + failure path
  pipeline.mojo         # multi-action workflow: fan-out + traces
  agent.mojo            # data-dependent tree: branching + a grandchild action
  resume.mojo           # a task that survives its own failure (checkpoints)
  inspect.mojo          # the control plane: what ran, how, why
  python_task.mojo/.py  # escape hatch: an existing Python task
tests/
  local_test.mojo       # 69 checks
  worker_checks.sh      # 60 worker/protocol checks (no cluster needed)
  simulate.py           # runs a multi-action tree locally, one process per action
  worker_flow.mojo      # fixture program for the worker-role checks
  worker_config.mojo    # fixture program for the configuration checks
  override_checks.py    # asserts a spec lands on a real TaskTemplate
  fixture_config.yaml   # fixed config so the suite is machine-independent
docs/
  design-notes.md       # what the four remaining gaps would actually take
_flyte_mojo/            # generated: builder Dockerfile + cached builds (gitignored)
```
