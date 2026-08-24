#!/usr/bin/env bash
# Worker-role checks: the parts of the SDK that only run inside an action pod.
#
# No cluster needed — the roles are selected by environment variables, so the
# whole protocol can be exercised by running the program directly.
set -u

# Every worker below runs without a shim, so nothing may inherit a terminal:
# a worker that asks for a child action blocks on stdin until it gets a reply.
exec 3<&0 <&-

pass=0
fail=0

check() {  # check <label> <expected-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "  PASS $1"; pass=$((pass + 1))
  else
    echo "  FAIL $1"; echo "        want /$2/"; echo "        got: $3"; fail=$((fail + 1))
  fi
}

count() {  # count <label> <regex> <expected-n> <actual>
  n=$(printf '%s\n' "$4" | grep -cE "$2")
  if [ "$n" -eq "$3" ]; then
    echo "  PASS $1"; pass=$((pass + 1))
  else
    echo "  FAIL $1"; echo "        want $3 lines matching /$2/, got $n"; fail=$((fail + 1))
  fi
}

refute() {  # refute <label> <forbidden-regex> <actual>
  if printf '%s' "$3" | grep -qE "$2"; then
    echo "  FAIL $1"; echo "        must not match /$2/"; echo "        got: $3"; fail=$((fail + 1))
  else
    echo "  PASS $1"; pass=$((pass + 1))
  fi
}

echo "== worker: the launched action emits a marked result =="
out=$(FLYTE_MOJO_ACTION=demo.hello mojo run -I . examples/hello.mojo 2>&1 </dev/null)
check "hello emits its result" '^__FLYTE_MOJO_OUTPUT__:hello, flyte2!$' "$out"

out=$(FLYTE_MOJO_ACTION=demo.hello mojo run -I . examples/hello.mojo mojo 2>&1 </dev/null)
check "the driver's argument wins over the replayed one" '__FLYTE_MOJO_OUTPUT__:hello, mojo!' "$out"

echo "== worker: a task reached only through another task can be launched =="
out=$(FLYTE_MOJO_ACTION=j.final mojo run -I . tests/worker_flow.mojo 2>&1 </dev/null)
check "j.final runs though main() never runs it directly" '__FLYTE_MOJO_OUTPUT__:final:n20' "$out"

echo "== worker: the journal replaces work already done =="
check "without a journal the earlier task re-executes" 'EXECUTED step\(2\)' "$out"

out=$(FLYTE_MOJO_ACTION=j.final FLYTE_MOJO_JOURNAL="$(printf 'j.step\t70\t2')" \
      mojo run -I . tests/worker_flow.mojo 2>&1 </dev/null)
refute "with a journal it does not re-execute" 'EXECUTED' "$out"
check "and its recorded result is what flows on" '__FLYTE_MOJO_OUTPUT__:final:n70' "$out"

echo "== worker: traces are reported only from inside the launched action =="
out=$(FLYTE_MOJO_ACTION=j.final FLYTE_MOJO_PROTOCOL=1 \
      FLYTE_MOJO_JOURNAL="$(printf 'j.step\t70\t2')" mojo run -I . tests/worker_flow.mojo 2>&1 </dev/null)
check "the trace opens a span" '__FLYTE_MOJO_SPAN__:begin\tj.label' "$out"
check "the trace closes it with its output" '__FLYTE_MOJO_SPAN__:end\tn70' "$out"

out=$(FLYTE_MOJO_ACTION=j.flow FLYTE_MOJO_PROTOCOL=1 \
      mojo run -I . tests/worker_flow.mojo 2>&1 </dev/null)
check "a nested task becomes a child-action request" '__FLYTE_MOJO_CALL__:call\tj.step\t\t2' "$out"

echo "== worker: groups are opened by the program, never implied =="
out=$(FLYTE_MOJO_ACTION=j.final FLYTE_MOJO_PROTOCOL=1 \
      FLYTE_MOJO_JOURNAL="$(printf 'j.step\t70\t2')" mojo run -I . tests/worker_flow.mojo 2>&1 </dev/null)
check "with group(...) opens one"  '__FLYTE_MOJO_GROUP__:begin\tfinishing' "$out"
check "and leaving the block closes it" '__FLYTE_MOJO_GROUP__:end' "$out"
count "exactly one group is opened" '__FLYTE_MOJO_GROUP__:begin' 1 "$out"

# j.step is inside no group at all, so its worker must announce none
out=$(FLYTE_MOJO_ACTION=j.step FLYTE_MOJO_PROTOCOL=1 mojo run -I . tests/worker_flow.mojo 2>&1 </dev/null)
refute "an ungrouped action announces no group" '__FLYTE_MOJO_GROUP__' "$out"

echo "== config: what the environment declares reaches the action =="
export FLYTE_MOJO_SIM_HOME="$(mktemp -d)"
out=$(python tests/simulate.py tests/worker_config.mojo c.root 3 2>&1)
check "an override beats the environment setting"  '^  c\.heavy\(3\)  \{cpu=4, memory=1Gi\}$' "$out"
check "a task with no override inherits it"        '^  c\.light\(3\)  \{cpu=1, memory=1Gi\}$' "$out"
check "and the workflow still computes"            'output: 10' "$out"

spec=$(python - <<'PY'
import sys; sys.path.insert(0, "flyte")
import flyte_mojo_shim as shim
print(shim.decode_spec("cpu=1\tmemory=1Gi\tcpu=4"))
print(shim.override_kwargs("cpu=1\tmemory=1Gi\tcpu=4"))
print(shim.override_kwargs("gpu=2\tgpu_type=A100"))
print("none:", shim.override_kwargs(""))
print("cache:", shim.override_kwargs("cache=auto"))
print("pinned:", shim.override_kwargs("cache=override\tcache_version=v2"))
PY
)
check "the later field wins"               "'cpu': '4'" "$spec"
check "which becomes a Flyte Resources"    "Resources\(cpu='4', memory='1Gi'" "$spec"
check "a typed GPU becomes device:count"   "gpu='A100:2'" "$spec"
check "an empty spec overrides nothing"    "none: \{\}" "$spec"
check "a bare cache behavior passes through" "cache: \{'cache': 'auto'\}" "$spec"
check "a pinned cache becomes a Cache"       "version_override='v2'" "$spec"

echo "== the whole protocol, driven end to end by the simulator =="
export FLYTE_MOJO_SIM_HOME="$(mktemp -d)"
out=$(python tests/simulate.py tests/worker_flow.mojo j.flow 2 2>&1)
check "the root action is the tree's root"      '^j\.flow\(2\)$' "$out"
check "its first task is a child"                '^  j\.step\(2\)$' "$out"
check "its second task sees the first's result"  '^  j\.final\(20\)$' "$out"
check "the trace nests inside the group"         '^      ~j\.label\(20\)$' "$out"
check "three actions, one trace, one group" '3 actions, 1 traces, 1 groups' "$out"
check "the group nests inside the action that opened it" '^    \[finishing\]$' "$out"
check "the result comes back through every hop" 'output: final:n20' "$out"
check "an upstream task runs exactly once across the whole tree" \
      "^$(printf '%s' "$out" | grep -c 'EXECUTED step')$" "1"

out=$(python tests/simulate.py examples/agent.mojo agent.solve "what is mojo" 2>&1)
count "fan-out produces one action per item" '^  agent\.search\(' 3 "$out"
check "a child action can have children of its own" '^    agent\.rerank\(' "$out"
check "and the branch taken is data-dependent" '^  agent\.answer\(what is mojo, sufficient\)$' "$out"

out=$(python tests/simulate.py examples/pipeline.mojo etl.pipeline 0 2>&1 || true)
check "a failing action reports the Mojo error" 'rows must be positive, got 0' "$out"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
