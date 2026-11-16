#!/usr/bin/env python3
"""
Wrap any bash script that calls `harbor run` and report its OpenRouter cost.

Flow:
  1. Validate the script (exists, `bash -n` syntax check, contains `harbor run`,
     `harbor` on PATH, OPENROUTER_API_KEY set)
  2. Fetch OpenRouter usage BEFORE
  3. Run the script (output streams live to the console)
  4. Fetch OpenRouter usage AFTER
  5. Print cost = after - before to the console and append it to a cost log file

Usage:
  export OPENROUTER_API_KEY=sk-or-v1-...
  python harbor_cost_run.py run_all.sh
  python harbor_cost_run.py --cost-log my_cost.txt run_all.sh arg1 arg2   # args go to the script
  python harbor_cost_run.py --check-only run_all.sh                       # validate only

Options must come BEFORE the script path; anything after it is passed to the script.
No third-party packages needed.

Note: cost is a delta on the whole API key, so a script with several `harbor run`
commands gives one combined cost, and any other use of the same key during the run
is counted too.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime

OPENROUTER_KEY_URL = "https://openrouter.ai/api/v1/key"


# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def fetch_key_info(api_key: str, retries: int = 3) -> dict:
    """Return the `data` object from GET /api/v1/key."""
    req = urllib.request.Request(
        OPENROUTER_KEY_URL,
        headers={"Authorization": f"Bearer {api_key}", "User-Agent": "harbor-cost-run/2.0"},
    )
    last_err = None
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.load(resp)["data"]
        except (urllib.error.URLError, TimeoutError, KeyError, json.JSONDecodeError) as e:
            last_err = e
            time.sleep(2 * attempt)
    raise RuntimeError(f"Failed to fetch OpenRouter key info: {last_err}")


def usd(x) -> str:
    return "n/a" if x is None else f"${x:,.6f}"


class Logger:
    """Print to console and append to the cost log file."""

    def __init__(self, path: str):
        self.path = path

    def __call__(self, msg: str = ""):
        print(msg, flush=True)
        with open(self.path, "a", encoding="utf-8") as f:
            f.write(msg + "\n")


def validate(script: str, require_harbor: bool) -> list[str]:
    """Return a list of problems (empty list = valid). Prints info on success."""
    problems = []

    if not os.path.isfile(script):
        return [f"Script not found: {script}"]

    if shutil.which("bash") is None:
        problems.append("`bash` not found on PATH.")
    else:
        r = subprocess.run(["bash", "-n", script], capture_output=True, text=True)
        if r.returncode != 0:
            problems.append(f"Bash syntax error:\n{r.stderr.strip()}")

    with open(script, encoding="utf-8", errors="replace") as f:
        lines = f.read().splitlines()
    # Count `harbor run` invocations on non-comment lines
    harbor_runs = [l for l in lines
                   if not l.lstrip().startswith("#") and re.search(r"\bharbor\s+run\b", l)]
    if require_harbor and not harbor_runs:
        problems.append("No `harbor run` command found in the script.")
    else:
        print(f"[check] found {len(harbor_runs)} `harbor run` command(s) in {script}")

    if shutil.which("harbor") is None:
        problems.append("`harbor` not found on PATH.")

    if not os.environ.get("OPENROUTER_API_KEY"):
        problems.append("OPENROUTER_API_KEY is not set (needed for the cost check and your script).")

    return problems


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
def main() -> int:
    p = argparse.ArgumentParser(
        description="Validate a bash script containing `harbor run`, run it, and report OpenRouter cost.",
    )
    p.add_argument("script", help="Bash script to run.")
    p.add_argument("script_args", nargs=argparse.REMAINDER, help="Arguments passed to the script.")
    p.add_argument("--cost-log", default="cost_log.txt", help="Cost log file (appended). Default: cost_log.txt")
    p.add_argument("--settle-delay", type=float, default=5.0,
                   help="Seconds to wait after the run before reading 'after' usage (default 5).")
    p.add_argument("--check-only", action="store_true", help="Only validate the script, don't run it.")
    p.add_argument("--no-require-harbor", action="store_true",
                   help="Don't fail if the script has no `harbor run` line.")
    args = p.parse_args()

    # 1. Validate
    problems = validate(args.script, require_harbor=not args.no_require_harbor)
    if problems:
        print("\nValidation failed:")
        for pr in problems:
            print(f"  - {pr}")
        return 2
    print("[check] script is valid")
    if args.check_only:
        return 0

    api_key = os.environ["OPENROUTER_API_KEY"]
    log = Logger(args.cost_log)

    # 2. Before
    before = fetch_key_info(api_key)
    started_at = datetime.now()
    log("=" * 72)
    log(f"Script        : {os.path.abspath(args.script)} {' '.join(args.script_args)}".rstrip())
    log(f"Started       : {started_at.isoformat(timespec='seconds')}")
    log(f"Usage before  : {usd(before['usage'])}")
    log("=" * 72)

    # 3. Run
    t0 = time.time()
    try:
        returncode = subprocess.run(["bash", args.script, *args.script_args]).returncode
    except KeyboardInterrupt:
        log("Interrupted by user; computing cost so far.")
        returncode = 130
    duration = time.time() - t0

    # 4. After
    time.sleep(args.settle_delay)
    after = fetch_key_info(api_key)

    # 5. Report
    cost = (after["usage"] or 0) - (before["usage"] or 0)
    log("")
    log("=" * 72)
    log("COST REPORT")
    log(f"Script        : {args.script}")
    log(f"Finished      : {datetime.now().isoformat(timespec='seconds')}  (duration {duration / 60:.1f} min)")
    log(f"Exit code     : {returncode}")
    log(f"Usage before  : {usd(before['usage'])}")
    log(f"Usage after   : {usd(after['usage'])}")
    log(f"RUN COST      : {usd(cost)}")
    if before.get("limit_remaining") is not None and after.get("limit_remaining") is not None:
        log(f"Remaining     : {usd(before['limit_remaining'])} -> {usd(after['limit_remaining'])}")
    log(f"Key           : {after.get('label')}  limit={after.get('limit')}")
    if returncode != 0:
        log(f"WARNING: script exited with code {returncode}; cost above still reflects actual spend.")
    log("=" * 72)
    log(f"(appended to {os.path.abspath(args.cost_log)})")

    return returncode


if __name__ == "__main__":
    sys.exit(main())