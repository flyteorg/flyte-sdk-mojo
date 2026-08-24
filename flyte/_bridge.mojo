"""The worker↔shim control protocol.

A compiled worker can do more than compute one value. When the shim drives
it over pipes (``FLYTE_MOJO_PROTOCOL=1``), the worker can ask Flyte to do
things on its behalf, and the shim answers:

    worker ── stdout ──▶ shim      shim ── stdin ──▶ worker
    CALL  call  fqn spec args...   OK   result
    CALL  map   fqn spec args...   OK   result result ...
    SPAN  begin fqn args...        ERR  message
    SPAN  end   output error
    GROUP begin name
    GROUP end
    CKPT  save text                OK
    CKPT  load                     OK   text
    OUTPUT value

``call`` becomes a Flyte child action (a new pod running this same binary);
``map`` becomes a parallel fan-out of them; ``SPAN`` brackets a Mojo trace
so the shim can hold a real ``flyte.trace`` context open for exactly as long
as the Mojo code runs. That is what makes the nesting show up in the UI.

Fields are tab-separated with backslash escapes, so a value containing a
tab or newline survives the trip. This module is pure Mojo — a task pod
never needs a Python interpreter of its own.
"""
from std.collections import List
from std.os import getenv

comptime PROTOCOL_ENV: String = "FLYTE_MOJO_PROTOCOL"

# Results the shim already has for child actions completed earlier in this
# run, so a worker replaying its way to a later action does not redo them.
comptime JOURNAL_ENV: String = "FLYTE_MOJO_JOURNAL"
comptime CALL_MARK: String = "__FLYTE_MOJO_CALL__:"
comptime SPAN_MARK: String = "__FLYTE_MOJO_SPAN__:"
comptime GROUP_MARK: String = "__FLYTE_MOJO_GROUP__:"
comptime CKPT_MARK: String = "__FLYTE_MOJO_CKPT__:"


def protocol_active() -> Bool:
    """True when a shim is driving this worker over pipes."""
    return getenv(PROTOCOL_ENV, "") != ""


# ---------------------------------------------------------------------------
# Field codec
# ---------------------------------------------------------------------------


def _escape(field: String) -> String:
    return field.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")


def _unescape(field: String) -> String:
    var out = String("")
    var pending = False
    for c in field.codepoint_slices():
        if pending:
            if c == "t":
                out += "\t"
            elif c == "n":
                out += "\n"
            elif c == "r":
                out += "\r"
            else:
                out += String(c)
            pending = False
        elif c == "\\":
            pending = True
        else:
            out += String(c)
    return out^


def _row(fields: List[String]) -> String:
    var escaped = List[String]()
    for f in fields:
        escaped.append(_escape(f))
    return String("\t").join(escaped)


def _reply() raises -> List[String]:
    """Read one answer from the shim; raise if it reports a failure."""
    var line = input()
    var parts = line.split("\t")
    var fields = List[String]()
    for p in parts:
        fields.append(_unescape(String(p)))
    if len(fields) == 0 or fields[0] == "":
        raise Error("flyte: the action shim closed the control channel")
    if fields[0] == "ERR":
        raise Error(fields[1] if len(fields) > 1 else String("child action failed"))
    var values = List[String]()
    for i in range(1, len(fields)):
        values.append(fields[i])
    return values^


def _send(mark: String, fields: List[String]):
    print(mark + _row(fields), flush=True)


# ---------------------------------------------------------------------------
# Requests
# ---------------------------------------------------------------------------


def call(fqn: String, spec: String, args: List[String]) raises -> String:
    """Run ``fqn`` as a Flyte child action and wait for its result.

    ``spec`` is the action's configuration (see ``_spec``), which the shim
    turns into a Flyte task override.
    """
    var fields: List[String] = ["call", fqn, spec]
    for a in args:
        fields.append(a)
    _send(CALL_MARK, fields)
    var values = _reply()
    if len(values) == 0:
        raise Error("flyte: child action " + fqn + " returned nothing")
    return values[0]


def map_call(fqn: String, spec: String, args: List[String]) raises -> List[String]:
    """Run ``fqn`` once per argument, as parallel child actions."""
    var fields: List[String] = ["map", fqn, spec]
    for a in args:
        fields.append(a)
    _send(CALL_MARK, fields)
    var values = _reply()
    if len(values) != len(args):
        raise Error(
            "flyte: fan-out over "
            + fqn
            + " returned "
            + String(len(values))
            + " results for "
            + String(len(args))
            + " inputs"
        )
    return values^


def span_begin(fqn: String, args: List[String]):
    """Open a trace span; the shim holds a flyte.trace context until end."""
    var fields: List[String] = ["begin", fqn]
    for a in args:
        fields.append(a)
    _send(SPAN_MARK, fields)


def span_end(output: String, error: String):
    var fields: List[String] = ["end", output, error]
    _send(SPAN_MARK, fields)


def group_begin(name: String):
    """Open a named region; the shim holds a flyte.group context for it."""
    var fields: List[String] = ["begin", name]
    _send(GROUP_MARK, fields)


def group_end():
    var fields: List[String] = ["end"]
    _send(GROUP_MARK, fields)


# ---------------------------------------------------------------------------
# The replay journal
#
# A worker launched for a late action still has to run main() to reach it, and
# that path crosses earlier task calls. Re-executing them would duplicate work
# and, worse, duplicate side effects. The shim therefore hands each child the
# results it already has: one record per line, `fqn output args...`.
# ---------------------------------------------------------------------------


@fieldwise_init
struct Memo(ImplicitlyCopyable):
    var found: Bool
    var value: String


def journal_lookup(fqn: String, args: List[String]) -> Memo:
    """The recorded result of ``fqn(args)``, if the shim already has one."""
    var raw = getenv(JOURNAL_ENV, "")
    if raw == "":
        return Memo(False, String(""))
    for line in raw.split("\n"):
        var row = String(line)
        if row == "":
            continue
        var fields = List[String]()
        for f in row.split("\t"):
            fields.append(_unescape(String(f)))
        if len(fields) < 2 or fields[0] != fqn:
            continue
        if len(fields) - 2 != len(args):
            continue
        var same = True
        for i in range(len(args)):
            if fields[i + 2] != args[i]:
                same = False
                break
        if same:
            return Memo(True, fields[1])
    return Memo(False, String(""))


def checkpoint_save(text: String) raises:
    """Hand the shim a checkpoint to persist for the next attempt."""
    var fields: List[String] = ["save", text]
    _send(CKPT_MARK, fields)
    _ = _reply()


def checkpoint_load() raises -> String:
    """The checkpoint a previous attempt left, or "" if this is the first."""
    var fields: List[String] = ["load"]
    _send(CKPT_MARK, fields)
    var values = _reply()
    return values[0] if len(values) > 0 else String("")
