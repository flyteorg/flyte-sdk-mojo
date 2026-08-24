"""Run a multi-action Mojo workflow locally, with no cluster.

This is a stand-in for the pod-side shim (``flyte_mojo_shim.py``). It speaks
the same control protocol, but a child action is a recursive ``mojo run`` of
the same program rather than a Flyte task, and a trace span is recorded
rather than opened on a cluster. The action tree it prints is the tree Flyte
would build.

    python tests/simulate.py examples/pipeline.mojo etl.pipeline 4

Use it to develop a workflow before paying for a cluster round trip, and to
test the protocol in CI.
"""

import os
import subprocess
import sys

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(_ROOT, "flyte"))

# The real pod-side runtime, imported straight out of the SDK package: the
# simulator and the cluster must agree on the protocol, not merely resemble
# each other.
import flyte_mojo_shim as shim  # noqa: E402


class _WorkerExit(Exception):
    """The worker closed stdout — its exit code explains why."""


class Sim:
    def __init__(self, program):
        self.program = program
        self.lines = []          # the action tree, as text
        self.actions = 0
        self.traces = 0
        self.groups = 0

    def _emit(self, depth, text):
        self.lines.append("  " * depth + text)

    def action(self, name, args, journal, depth=0, spec=""):  # noqa: C901
        """Run one action of the program, servicing what it asks for."""
        self.actions += 1
        label = "%s(%s)" % (name, ", ".join(args))
        if spec:
            # what the cluster would have applied, so the tree shows it
            label += "  {%s}" % ", ".join(
                "%s=%s" % kv for kv in sorted(shim.decode_spec(spec).items())
            )
        self._emit(depth, label)
        proc = subprocess.Popen(
            ["mojo", "run", "-I", ".", self.program, *args],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            cwd=_ROOT,
            env={
                **os.environ,
                "HOME": os.environ.get("FLYTE_MOJO_SIM_HOME", os.environ["HOME"]),
                "FLYTE_MOJO_ACTION": name,
                "FLYTE_MOJO_PROTOCOL": "1",
                "FLYTE_MOJO_JOURNAL": "\n".join(journal),
            },
        )
        logs = []
        result = None
        try:
            result = self._pump(proc, journal, depth, logs)
        except _WorkerExit:
            pass  # the exit code below is the real story
        finally:
            proc.stdin.close()
            code = proc.wait()
            logs.extend(proc.stdout.read().splitlines())
            logs.extend(proc.stderr.read().splitlines())
        if code != 0:
            raise RuntimeError(
                "action %s failed (exit %d): %s"
                % (name, code, shim.reason(logs) or "no output")
            )
        if result is None:
            raise RuntimeError("action %s produced no result" % name)
        return result

    def _pump(self, proc, journal, depth, logs):
        open_groups = 0
        while True:
            line = proc.stdout.readline()
            if line == "":
                raise _WorkerExit()
            line = line.rstrip("\n")

            if line.startswith(shim.OUTPUT_MARK):
                return line[len(shim.OUTPUT_MARK):]

            if line.startswith(shim.GROUP_MARK):
                fields = shim._decode_row(line[len(shim.GROUP_MARK):])
                if fields[0] == "begin":
                    self.groups += 1
                    self._emit(depth + 1, "[%s]" % fields[1])
                    open_groups += 1
                    depth += 1
                elif open_groups:
                    open_groups -= 1
                    depth -= 1
                continue

            if line.startswith(shim.CALL_MARK):
                fields = shim._decode_row(line[len(shim.CALL_MARK):])
                kind, fqn, spec, rest = fields[0], fields[1], fields[2], fields[3:]
                snapshot = list(journal)
                try:
                    if kind == "map":
                        outputs = [
                            self.action(fqn, [item], snapshot, depth + 1, spec)
                            for item in rest
                        ]
                        for item, out in zip(rest, outputs):
                            journal.append(shim._encode_row([fqn, out, item]))
                        reply = ["OK", *outputs]
                    else:
                        out = self.action(fqn, list(rest), snapshot, depth + 1, spec)
                        journal.append(shim._encode_row([fqn, out, *rest]))
                        reply = ["OK", out]
                except Exception as exc:
                    reply = ["ERR", "%s: %s" % (fqn, exc)]
                proc.stdin.write(shim._encode_row(reply) + "\n")
                proc.stdin.flush()
                continue

            if line.startswith(shim.SPAN_MARK):
                fields = shim._decode_row(line[len(shim.SPAN_MARK):])
                if fields[0] == "begin":
                    self.traces += 1
                    self._emit(depth + 1, "~%s(%s)" % (fields[1], ", ".join(fields[2:])))
                    self._pump(proc, journal, depth + 1, logs)  # until the span ends
                    continue
                error = fields[2] if len(fields) > 2 else ""
                if error:
                    raise RuntimeError(error)
                return fields[1] if len(fields) > 1 else ""

            logs.append(line)
            self._emit(depth, "| " + line)


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    program, action, args = argv[1], argv[2], argv[3:]
    sim = Sim(program)
    output = sim.action(action, args, [])
    print("\n".join(sim.lines))
    print()
    print("%d actions, %d traces, %d groups" % (sim.actions, sim.traces, sim.groups))
    print("output:", output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
