# scripts/guard.py — the PreToolUse rules behind scripts/guard.sh (hook JSON on stdin, hub dir as argv[1]).
# Exit 2 refuses the tool call (stderr is the reason shown to the session); exit 0 allows it.
import json, os, re, sys

hub = os.path.realpath(sys.argv[1])
try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)                      # unreadable payload: never block on a hook bug

tool = payload.get("tool_name", "")
inp = payload.get("tool_input", {}) or {}

NEVER_OPEN = ["CHANGELOG.md", "METRICS.md", "metrics/ledger.jsonl"]
NEVER_EDIT = ["templates/", "SPEC-GUIDELINES.md", "AGENTS.md"]
SANCTIONED = ("scripts/changelog.sh", "scripts/metrics.sh")
WRITE_OPS = re.compile(r"(>|\bsed\s+-i\b|\btee\b|\bmv\b|\bcp\b|\brm\b|\btruncate\b)")
# Redirects that write no file: discarding to /dev/null (2>/dev/null, &>/dev/null, >>/dev/null)
# and fd duplication (2>&1, >&2). Removed before WRITE_OPS so a read-only grep is not refused.
HARMLESS_REDIRECTS = re.compile(r"(?:\d|&)?>>?\s*/dev/null\b|\d?>&\d")

def rel(path):
    """Path relative to the hub, or None when the path lies outside it."""
    if not path:
        return None
    p = os.path.realpath(path if os.path.isabs(path) else os.path.join(hub, path))
    if p == hub or p.startswith(hub + os.sep):
        return os.path.relpath(p, hub)
    return None

def refuse(msg):
    sys.stderr.write("spechub guard: " + msg + "\n")
    sys.exit(2)

def hits(text, names):
    return [n for n in names if n in text]

# ---- rule 1: never open the observability files
if tool in ("Read", "Grep", "Glob"):
    r = rel(inp.get("file_path") or inp.get("path") or "")
    if r is not None:
        h = hits(r + ("/" if os.path.isdir(os.path.join(hub, r)) else ""), NEVER_OPEN)
        if h:
            refuse(f"{h[0]} is never opened in a session (AGENTS.md > Context Budget). "
                   "Use `scripts/changelog.sh add \"<entry>\"` to add a changelog entry and "
                   "`scripts/metrics.sh report` / `render` for metrics.")
elif tool == "Bash":
    cmd = inp.get("command", "") or ""
    stripped = cmd.strip()
    if not stripped.startswith(SANCTIONED) and not re.match(r"^\S*/(changelog|metrics)\.sh\b", stripped):
        h = hits(cmd, NEVER_OPEN)
        if h:
            refuse(f"the command names {h[0]}, which is never opened in a session (AGENTS.md > Context Budget). "
                   "Use `scripts/changelog.sh add \"<entry>\"` or `scripts/metrics.sh report` / `render` instead.")

# ---- rule 2: never edit the contract files
if tool in ("Edit", "Write", "MultiEdit", "NotebookEdit"):
    r = rel(inp.get("file_path") or inp.get("notebook_path") or "")
    if r is not None:
        rr = r + ("/" if os.path.isdir(os.path.join(hub, r)) else "")
        h = [n for n in NEVER_EDIT if rr == n or rr.startswith(n) or rr.endswith("/" + n)]
        if h:
            refuse(f"{r} is a workflow contract file (templates/, SPEC-GUIDELINES.md, AGENTS.md) and is never "
                   "edited from a session. Append the case to bootstrap/OBSERVATIONS.md instead; a human promotes "
                   "it into a rule between runs. (Framework work: start the session with SPECHUB_GUARD=off.)")
elif tool == "Bash":
    cmd = inp.get("command", "") or ""
    if WRITE_OPS.search(HARMLESS_REDIRECTS.sub(" ", cmd)):
        h = hits(cmd, NEVER_EDIT)
        if h:
            refuse(f"the command writes to {h[0]}, a workflow contract file that is never edited from a session. "
                   "Append the case to bootstrap/OBSERVATIONS.md instead. (Framework work: SPECHUB_GUARD=off.)")

sys.exit(0)
