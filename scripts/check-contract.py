#!/usr/bin/env python3
r"""Static contract checks for ai-review (no network, no secrets).

1. Prompt env-var contract: every `env \`VAR\`` / `$VAR` referenced in
   prompts/*.md is either set in some workflow `env:` block or is a GitHub
   auto-provided variable. Catches a playbook that reads a var nobody sets.
2. Template permission superset: each caller template's job `permissions:`
   must be a superset of every permission the reusable workflow's jobs request
   (and the nested review.yml call inside commands.yml is checked too).
   Reusable workflows can only *downgrade*, so the caller must grant the max.
3. Reconcile drift-guard: the canonical state-marker `capture(...)` regex used
   by scripts/lib/reconcile.sh must still appear verbatim in the gate job's
   inline parser, so the unit-tested lib can't silently diverge from the YAML.

Run from repo root: python3 scripts/check-contract.py
Exit non-zero on any violation.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"
PROMPTS = ROOT / "prompts"
TEMPLATES = ROOT / "templates"

# GitHub provides these automatically in every job; prompts may read them even
# though no `env:` block sets them.
AUTO_VARS = re.compile(r"^(GITHUB_|RUNNER_|CI$|HOME$|PATH$)")

# Permission ranking: a caller granting `write` satisfies a `read` request.
PERM_RANK = {"none": 0, "read": 1, "write": 2}

errors: list[str] = []


def err(msg: str) -> None:
    print(f"::error::{msg}", file=sys.stderr)
    errors.append(msg)


# --- 1: prompt env-var contract ---------------------------------------------
def workflow_env_vars() -> set[str]:
    found: set[str] = set()
    # `env:` blocks are nested mappings; a cheap line scan for `NAME:` keys
    # under any indentation is sufficient and avoids full graph walking.
    key_re = re.compile(r"^\s+([A-Z_][A-Z0-9_]+):\s")
    for wf in WORKFLOWS.glob("*.yml"):
        for line in wf.read_text().splitlines():
            m = key_re.match(line)
            if m:
                found.add(m.group(1))
    return found


def prompt_referenced_vars() -> set[str]:
    ref: set[str] = set()
    pat = re.compile(r"env `([A-Z_][A-Z0-9_]+)`|\$\{?([A-Z_][A-Z0-9_]+)\}?")
    for md in PROMPTS.glob("*.md"):
        for a, b in pat.findall(md.read_text()):
            ref.add(a or b)
    return ref


def check_prompt_contract() -> None:
    provided = workflow_env_vars()
    for var in sorted(prompt_referenced_vars()):
        if AUTO_VARS.match(var):
            continue
        if var not in provided:
            err(f"prompt references ${var} but no workflow env: sets it")


# --- 2: template permission superset ----------------------------------------
def job_permissions(doc: dict) -> list[dict[str, str]]:
    """Return each job's permissions mapping (skipping jobs without one)."""
    out = []
    for job in (doc.get("jobs") or {}).values():
        if isinstance(job, dict) and isinstance(job.get("permissions"), dict):
            out.append({k: str(v) for k, v in job["permissions"].items()})
    return out


def max_permissions(doc: dict) -> dict[str, str]:
    """Max permission requested per scope across all jobs in a workflow."""
    acc: dict[str, str] = {}
    for perms in job_permissions(doc):
        for scope, level in perms.items():
            if PERM_RANK.get(level, 0) > PERM_RANK.get(acc.get(scope, "none"), 0):
                acc[scope] = level
    return acc


def assert_superset(label: str, granted: dict[str, str], needed: dict[str, str]) -> None:
    for scope, level in needed.items():
        have = granted.get(scope, "none")
        if PERM_RANK.get(have, 0) < PERM_RANK.get(level, 0):
            err(f"{label}: grants {scope}:{have} but a downstream job needs {scope}:{level}")


def load(path: Path) -> dict:
    return yaml.safe_load(path.read_text())


def check_permissions() -> None:
    review = load(WORKFLOWS / "review.yml")
    commands = load(WORKFLOWS / "commands.yml")
    review_max = max_permissions(review)
    commands_max = max_permissions(commands)

    # caller-review -> review.yml
    cr = load(TEMPLATES / "caller-review.yml")
    cr_perms = job_permissions(cr)
    if not cr_perms:
        err("caller-review.yml: no job permissions block found")
    else:
        assert_superset("caller-review.yml", cr_perms[0], review_max)

    # caller-commands -> commands.yml (which itself nests review.yml)
    cc = load(TEMPLATES / "caller-commands.yml")
    cc_perms = job_permissions(cc)
    if not cc_perms:
        err("caller-commands.yml: no job permissions block found")
    else:
        # commands.yml's own jobs include a nested review job whose declared
        # permissions must already cover review.yml; fold both in.
        needed = dict(commands_max)
        for scope, level in review_max.items():
            if PERM_RANK.get(level, 0) > PERM_RANK.get(needed.get(scope, "none"), 0):
                needed[scope] = level
        assert_superset("caller-commands.yml", cc_perms[0], needed)


# --- 3: reconcile drift-guard -----------------------------------------------
CANON = 'capture("<!-- ai-review:state (?<j>.*?) -->"; "s")'


def check_drift_guard() -> None:
    lib = (ROOT / "scripts" / "lib" / "reconcile.sh").read_text()
    if CANON not in lib:
        err("reconcile.sh no longer contains the canonical state-marker capture regex")
    gate = (WORKFLOWS / "review.yml").read_text()
    if CANON not in gate:
        err("review.yml gate inline parser diverged from reconcile.sh capture regex")


def main() -> int:
    check_prompt_contract()
    check_permissions()
    check_drift_guard()
    if errors:
        print(f"contract check FAILED ({len(errors)} issue(s))", file=sys.stderr)
        return 1
    print("contract check OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
