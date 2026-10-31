#!/usr/bin/env bash
# scripts/python.sh — the Python 3 interpreter behind the hub scripts. Sourced, never run:
#
#   . "$HUB_DIR/scripts/python.sh"        # then:  hub_python <arguments as for python3>
#
# `python3` on PATH is used wherever it is a real interpreter — macOS, Linux, and a Windows with
# Python installed under that name. A stock Windows PATH holds only the Microsoft Store stub under
# that name (WindowsApps/python3: it never runs anything and exits 126/9009), so that one is skipped
# and the `py -3` launcher, then a Python-3 `python`, are tried instead. The choice is exported as
# HUB_PYTHON so child scripts (stack → dispatch → metrics) do not probe again; HUB_PYTHON set by hand
# wins ("py -3.12", "/opt/homebrew/bin/python3.12", …).
#
# Windows Python defaults to the ANSI code page: PYTHONUTF8=1 makes it read and print UTF-8 (the
# specs are UTF-8); it changes nothing on macOS/Linux. Git Bash converts POSIX paths in the arguments
# and the environment (/c/… → C:/…) before a native program sees them, so callers pass paths as usual.

hub_python_find() {
  local p
  if p="$(command -v python3 2>/dev/null)" && [ -n "$p" ]; then
    case "$p" in */WindowsApps/*) ;; *) printf '%s\n' python3; return 0 ;; esac
  fi
  if command -v py >/dev/null 2>&1 && py -3 -c 'import sys' >/dev/null 2>&1; then printf '%s\n' 'py -3'; return 0; fi
  if command -v python >/dev/null 2>&1 && python -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' >/dev/null 2>&1; then printf '%s\n' python; return 0; fi
  return 1
}

if [ -z "${HUB_PYTHON:-}" ]; then
  HUB_PYTHON="$(hub_python_find)" || HUB_PYTHON=""
fi
export HUB_PYTHON
export PYTHONUTF8=1

# hub_python <args...> — run the interpreter; a clear error when there is none (exit 127).
hub_python() {
  [ -n "${HUB_PYTHON:-}" ] || { printf '[hub] ERROR: no Python 3 found (python3, py -3 or python) — install Python 3.7+ or set HUB_PYTHON\n' >&2; return 127; }
  # shellcheck disable=SC2086  # HUB_PYTHON may be a command with an option ("py -3")
  $HUB_PYTHON "$@"
}
