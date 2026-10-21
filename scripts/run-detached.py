#!/usr/bin/env python3
"""Detach a long-running command into a new session (survives parent exit).

Usage:
    run-detached.py <log-file> <pid-file> <command> [args...]

The child starts with start_new_session=True (PPID 1), stdin from
/dev/null, stdout/stderr appended to <log-file>. Prints the child PID to
stdout and records it in <pid-file>. Never prints command output or any
secret material; only the PID.

macOS has no `setsid`; this is the equivalent detach primitive for
release/notarization waits. Exits non-zero with the reason on stderr when
the child cannot be started.
"""

import os
import subprocess
import sys


def main(argv):
    if len(argv) < 4:
        print(
            "usage: run-detached.py <log-file> <pid-file> <command> [args...]",
            file=sys.stderr,
        )
        return 2
    log_path, pid_path, command = argv[1], argv[2], argv[3]
    child_args = argv[3:]
    env = dict(os.environ)
    env["NEATGIT_RELEASE_CHILD"] = "1"
    try:
        log_file = open(log_path, "ab")
    except OSError as exc:
        print("cannot open log file: %s" % exc, file=sys.stderr)
        return 1
    try:
        proc = subprocess.Popen(
            child_args,
            stdin=subprocess.DEVNULL,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            env=env,
            start_new_session=True,
            close_fds=True,
        )
    except OSError as exc:
        log_file.close()
        print("cannot start detached child: %s" % exc, file=sys.stderr)
        return 1
    log_file.close()
    try:
        with open(pid_path, "w") as handle:
            handle.write("%d\n" % proc.pid)
    except OSError as exc:
        print("child started (pid %d) but pid file failed: %s" % (proc.pid, exc))
        return 1
    print(proc.pid)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
