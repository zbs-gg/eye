#!/usr/bin/python3
"""Launch one adapter as a new session so its full descendant tree is killable."""

import os
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: process_group_launcher.py EXECUTABLE [ARG ...]", file=sys.stderr)
        return 2
    if os.getpgrp() != os.getpid():
        os.setsid()
    executable = sys.argv[1]
    os.execve(executable, [executable, *sys.argv[2:]], os.environ.copy())
    return 127


if __name__ == "__main__":
    raise SystemExit(main())
