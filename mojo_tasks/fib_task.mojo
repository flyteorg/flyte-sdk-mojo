"""Fibonacci task — a CPU-bound task body in compiled Mojo.

Protocol: argv[1] = n (integer, 0 <= n < 92); stdout = fib(n); non-zero exit = failure.
Demonstrates native-speed computation inside a Flyte 2 action.
"""
from std.sys import argv


def fib(n: Int) -> Int:
    var a: Int = 0
    var b: Int = 1
    var i: Int = 0
    while i < n:
        var t = a + b
        a = b
        b = t
        i += 1
    return a


def main() raises:
    var args = argv()
    if len(args) < 2:
        raise Error("usage: fib <n>")
    var n: Int = Int(args[1])
    if n < 0 or n > 91:
        raise Error("n out of range (0..91): " + String(n))
    print(String(fib(n)))
