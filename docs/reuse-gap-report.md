# How much of container reuse is actually here

`design-notes.md` opened by listing container reuse among the things that "all
landed". It has not. What landed is the **launch half** of a feature that has
two ends: a `Reuse` policy can be written in `.mojo`, encoded into the action
spec, and asserted onto a real `TaskTemplate`, and the SDK can say nothing at
all about what happens after that. Measured against the reference
implementations — `union-reuse` (Rust), `union-reuse-go` (Go), and
`unionai-reuse-mojo` (a pure-Mojo replica) — this SDK is at roughly **a quarter
of the end-to-end story**: about 70% of the client-side policy surface, and 0%
of the replica that a pool needs in order to exist.

That is not a criticism of the half that is here, which is well built. It is a
correction of the claim, plus a map of what the other half costs.

**Status.** The scorecard and the defect list below are the *as-found* state. Of
the four steps at the end, step 1 — the launch half — is done in this change, in
`flyte/_spec.mojo`, `flyte/flyte_mojo_shim.py` and the two test files. Steps 2-4
are not, so the ~quarter figure stands.

---

## Scorecard

| Layer | State | Where |
|---|---|---|
| Policy type + compile-time encoding | ~70% | `flyte/_spec.mojo` `Reuse`, `encode_reuse` |
| Env-level setting, per-task/run/map override | ✅ | `flyte/_env.mojo:34,53-103` |
| Spec → `TaskTemplate.override(reusable=…)` | ✅ | `flyte/flyte_mojo_shim.py` `_reuse`/`override_kwargs`, `tests/override_checks.py` |
| Image exposes `unionai-actor-bridge` | ❌ 0% | the Dockerfile the SDK writes (`_flyte_mojo_state.py:822`) builds a *builder* image; the task image is Flyte's default plus a code bundle |
| Replica runtime (fasttask lease) | ❌ 0% | no `fasttask`/`heartbeat`/`lease`/`ASSIGN` anywhere in `flyte/` |
| Semantics of a shared, long-lived process | ❌ unaddressed | `shim.drive` execs once, reads one marked line, `exit(0)` |
| Verification | one unit test | `bd37619`: the live runs hung in `WAITING_FOR_RESOURCES`, were aborted, and the example was reverted |

---

## What is genuinely solid

The policy travels with the action the same way every other setting does:
`Reuse` is a compile-time struct, `encode_reuse` folds it into the tab-separated
spec, env-level settings are appended before the task's so the task wins, and
"unset encodes as absent" means an environment's policy survives a call site
that says nothing. `tests/override_checks.py` proves the policy arrives on a
real `TaskTemplate` as `replicas=(2,2)`, and that a policy with no `replicas` is
no policy at all. Nothing about that mechanism needs to change.

## Defects in the half that shipped

All of these were reproduced against the pinned `flyte` 2.6.3 in `.venv`, by
calling `shim.override_kwargs` / `shim.configured` directly:

```
reuse + secrets       → ValueError from Flyte, not from the SDK
                        "Cannot override secrets when reusable is set"
idle_ttl=10           → ValueError from Flyte at dispatch, not at bind time
scope=local           → ValueError from Flyte at dispatch
reuse_scaledown_ttl   → not emitted by the encoder at all
replicas=(1,3)        → unrepresentable: field_int, and the shim does int()
```

**`scaledown_ttl` is missing.** `ReusePolicy` defaults it to 30s and it is a
separate knob from `idle_ttl` — the whole pool's idle timeout versus the delay
before one *individual* replica is removed during autoscaling. Not reachable
from `.mojo`, so every pool gets 30s and bursty workloads scale down between
waves.

**No autoscaling range.** `ReusePolicy.replicas` is `int | (min, max)`;
`encode_reuse` uses `field_int` and the shim does `int(replicas)`, so the SDK
can only ever build a *fixed* pool — `min_replica_count == replica_count` in the
`FastTaskEnvironmentSpec`. Every example in the reference repos uses
`replicas=(1, 3)`: pay-for-what-you-use scaling is the headline reason to want
a pool rather than a deployment, and it is the one thing this SDK cannot ask
for.

**No way to turn reuse off, which is the documented footgun.** Flyte's escape
hatch is `override(reusable="off")` (`_task.py:400,448`). The Mojo codec can
only *add* fields, so once an environment declares a policy every action of the
program is reusable — including the root action, which `remote_run_mojo` runs
through `configured()` too. `union-reuse/README.md:58` leads its cautions with
"Orchestrate from outside the pool", and this SDK cannot.

That is worse than it sounds because of how the shim is generated: **all actions
of a program are tasks on one `flyte.TaskEnvironment`** (`_flyte_mojo_state.py`
renders `env = flyte.TaskEnvironment(name="mojo_<program>")`), and pool identity
is `env_name + container + policy + code-bundle version`
(`flyte/_internal/runtime/reuse.py:36-58`). So a reusable program's parent and
its children are *the same pool* — the parent holds a replica while it blocks in
`_service_call` awaiting a child that needs a replica. Deadlock at `replicas=1`,
throughput cliff above it. `bd37619` launched a `reuse.mojo` probe from the
environment and from a call site, aborted both, and reverted the example before
committing. Its two actions — a root and a child, both generated onto the one
environment — would have starved each other even on a host where pools are
enabled, and nothing in the repo records that it was tried.

**The conflict guard covers one third of the conflicts.** The README said the
SDK raises "in its own terms rather than letting Flyte's error surface from
inside the shim" — for `Resources`, true. `TaskTemplate.override` refuses
`resources`, `env_vars` **and** `secrets` when a policy is set
(`_task.py:451-468`), and `Secrets` + `Reuse` is an entirely plausible
combination, so the promised translation is missing for the case users are most
likely to hit.

**Nothing is validated where the value is known.** `ReusePolicy.__post_init__`
rejects `idle_ttl < 30`, `scaledown_ttl < 30` and a `scope` outside
`global`/`run`, and warns when `max_replicas == 1 and concurrency == 1` — all of
which are checkable in `.mojo`, where `Reuse` is a compile-time struct. Today a
typo'd `scope` on a *child* action is raised by `configured()` inside the parent
pod, mid-run, and surfaces as a failed action.

## The other half: what a pool actually needs

Per `union-reuse/README.md:60-80` and `union-reuse-go`'s `doc.go`, declaring a
policy does not merely annotate the task. The backend **replaces the container's
args** with

```
unionai-actor-bridge --parallelism N --queue-id … --worker-id … --fasttask-url …
```

and streams work to that process over `fasttask.FastTask/Heartbeat`, an
`ActionDataAssign`/`ActionDataStatus` bidirectional gRPC stream
(`flyte-unionai/fasttask/protos/fasttask.proto`, vendored into the Mojo replica
as `proto/fasttask.proto`). The image must answer to the
name `unionai-actor-bridge` — a symlink to the worker binary — and the binary
must enter pool mode when it sees `--queue-id`/`--worker-id` instead of running
its own task.

Verified against the pinned SDK: `fasttask` and `actor-bridge` appear nowhere in
the installed `flyte` package, and `unionai-e2go` is not among its dependencies.
**The Python SDK ships no client for this protocol either** — every language
ships its own bridge (`unionai-reuse` for Python, `union-reuse-go`,
`union-reuse`), and the launcher library on that language's side adds the symlink
to the image. `union-reuse-go/examples/reusable/task.py` is explicit: "reuse
just adds one step, giving the binary the second name (unionai-actor-bridge) a
pool replica is launched under." (line 11)

So the `WAITING_FOR_RESOURCES` observation has an obvious reading — nothing in
the image resolved as a replica, so no worker ever registered against the queue
— and it was never distinguished from "pools are not enabled on that host".
Neither is provable from the SDK as it stands, which is the real finding.

What a replica must implement, none of which exists in this repo:

- hold the lease and heartbeat capacity, including a final zero-capacity beat
  so the platform can reclaim the queue;
- accept `ASSIGN` and start what it names — in-process on a goroutine for the
  Go replica, a forked process per assignment for the Rust and Mojo ones —
  `ACK` it, stream `ActionDataStatus` to a terminal phase, distinguish a
  retryable `FAILED` from `FAILED_PERMANENT`, and set `system_failure` when the
  action never started at all;
- take identity from **the assignment's env map, never the process env** —
  `union-reuse-go/pool.go:14-18`: process env "is fixed for the replica's
  lifetime and names whichever action came first", so every action that
  inherits it is logged, checkpointed and attributed to the wrong run;
- kill what is in flight on `DELETE`/cancel and on `SIGTERM`, and reconnect on
  a dropped stream.

## What `unionai-reuse-mojo` already hands us

It is the missing layer, in the same language, with the wire written down:
`_cli.mojo` (the pool argv), `_pb/_hpack/_hufftree/_http2/_grpc` (protobuf
codec, HPACK with Huffman, HTTP/2 over h2c, gRPC frames — no external dep),
`_pool.mojo` and `_posix.mojo` (fork-per-assignment, cancel, kill, reap, and the
syscalls under it), `_manager.mojo` (the lease state machine: capacity, statuses,
ACK/DELETE, dirty flush, final beat), `_serve.mojo`, and
`tests/fake_fasttask_server.py` — a scripted real-gRPC plugin that answers a
replica *without a control plane*. The plugin-phase numbers in
`_phase.mojo` carry the "must match flyteplugins core/phase.go numerically"
warning that is expensive to rediscover.

Its one assumption is that the assignment names something this binary already
contains — true for Go and Rust, where the image *is* the task binary, and false
here, where the task's payload is a Python shim plus a code bundle. That is what
the next section is about.

## The decision that sizes everything else: what is the ASSIGN command?

For a Mojo action today the answer would be the generated Python shim — the
container command of every task here is Flyte's Python entrypoint, and the Mojo
binary is delivered in the code bundle and exec'd by `shim.drive`. So a warm
Mojo pod would still pay a Python interpreter, a `flyte` import, a code-bundle
fetch, and a fresh `task_binary` **per action**: pod scheduling and image pull
saved, everything else not. That is worth having, but it is not "warm".

The alternative — route assignments straight to the Mojo binary, so a replica is
the binary in pool mode and Python leaves the hot path entirely — needs the task
template's container command to be the binary rather than the shim, and it needs
the binary to speak fasttask. That is the version that would actually
differentiate this SDK, and it is the version the reference repo was built for.

## Plan

1. **Fix the launch half** — *done in this change*. `scaledown_ttl`, a
   min/max replica range (`Reuse(replicas=1, max_replicas=3)`), `Reuse(off=True)`
   as the escape hatch and the re-arm that follows it, the conflict guard
   extended to `Secrets`, Flyte's policy validation mirrored into the shim's own
   words (including a ceiling with no floor, which is otherwise silently
   ignorable), `local_test.mojo` pinning the encoding of all of it, and
   `override_checks.py` pinning the decode, the way a call site's field layers
   over the environment's, and every rejection — 35 checks, up from 18, and now
   run by `make test`, which had never run them. The `design-notes.md` claim,
   the `Reuse` docstring and the README table now say what reuse is and does
   rather than implying it works.

   What that change deliberately does *not* do is raise on a one-slot pool.
   A single warm replica is a legitimate shape for a leaf task, and Flyte warns
   about it generically; the SDK warns too, with the reason it is worse here.
2. **Prove the launch half against a pool.** Point the reference repo's
   `fake_fasttask_server.py` at a TaskSpec serialized from this SDK's shim and
   answer the two open questions with evidence, on a laptop: does a template
   built here produce a queue, and what `cmd`/`envVars` does the ASSIGN carry?
   The server side is not even a blocker for the harder version of this — the
   fasttask plugin, its worker, the proto and a single-binary Flyte config all
   live in `~/git/flyte-unionai/fasttask`, whose README drives a replica with
   `worker bridge --queue-id=…`. So the question can be settled against the
   real plugin in a sandbox rather than a stand-in. Cheapest evidence in the
   whole plan, and its answer decides whether step 3 is a symlink or a new
   entrypoint.
3. **Ship a replica.** Vendor the reference bridge as a second name of the task
   binary and add the image layer that gives it that name. Nothing user-visible
   until this exists.
4. **Then, and only then, the semantics** — per-assignment identity, `concurrency
   > 1` (N binaries sharing one pod's stdout and one memory limit), replay and
   its side effects per assignment rather than per pod, and what `flyte.ctx()`
   and checkpoints mean for a process that serves many actions.

Step 1 is an afternoon, and it is the only one of the four that could be done
without a cluster. Step 2 is also an afternoon and is worth doing before
anything is promised about reuse. Steps 3 and 4 are each larger than everything
currently in `flyte/`.
