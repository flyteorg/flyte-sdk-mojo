"""Wire conversion for remote runs.

Arguments and results cross three boundaries on their way to a cluster and
back — Mojo driver, Python control plane, Mojo worker — so they travel as
strings. ``to_wire`` is just ``String(v)`` (every task type is already
``Writable``); ``from_wire`` is the inverse, resolved at compile time
against the concrete type.

Only the scalar types below round-trip. That is a real limit, not an
oversight: a Mojo type has no general "parse me from a string" trait to
hook into. ``supported_on_wire`` lets callers degrade gracefully instead
of failing — see ``_core._wire_arg``.
"""


def supported_on_wire[T: Writable & Copyable & Deinitable]() -> Bool:
    """True when ``from_wire[T]`` can reconstruct a value."""
    comptime if T == String or T == Int or T == Float64 or T == Bool:
        return True
    else:
        return False


def to_wire[T: Writable & Copyable & Deinitable](v: T) -> String:
    return String(v)


def from_wire[T: Writable & Copyable & Deinitable](s: String) raises -> T:
    """Rebuild a ``T`` from its wire form. Raises for unsupported types."""
    comptime if T == String:
        return rebind[T](String(s)).copy()
    elif T == Int:
        return rebind[T](Int(s)).copy()
    elif T == Float64:
        return rebind[T](Float64(s)).copy()
    elif T == Bool:
        return rebind[T](s == "True" or s == "true" or s == "1").copy()
    else:
        raise Error(
            "flyte: remote runs can only carry String, Int, Float64 and Bool"
            " values; got a type that cannot be read back from '" + s + "'."
        )
