#!/usr/bin/env python3
"""Antigravity PreToolUse permission gate for AI Landing Zone Reference Validation.

Enforces the workspace allow/deny rules migrated from `.claude/settings.json`
and safety rules from `AGENTS.md`:
- Hard-denies reading `~/.config/gcloud/**` and `~/.lzv-redaction-map.json`.
- Hard-denies `git push`, org-level IAM mutations, and project/folder deletions.
- Auto-allows read-only `gcloud`, `terraform fmt/validate/version`, `bash -n`,
  `shellcheck`, `jq`, `tools/redact.py`, `tools/test_redact.py`, and local `git` commands.
- Prompts (`ask`) for all other commands.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Dict, List, Set, Tuple

# Denied command patterns (migrated from .claude/settings.json)
DENY_COMMAND_PATTERNS: List[Tuple[re.Pattern[str], str]] = [
    (
        re.compile(r"^(?:git)\s+push(?:\s+.*)?$", re.IGNORECASE),
        "Hard Deny: 'git push' is prohibited by workspace safety policy (AGENTS.md).",
    ),
    (
        re.compile(r"^gcloud\s+organizations\s+set-iam-policy(?:\s+.*)?$", re.IGNORECASE),
        "Hard Deny: 'gcloud organizations set-iam-policy' is prohibited by workspace policy.",
    ),
    (
        re.compile(r"^gcloud\s+organizations\s+add-iam-policy-binding(?:\s+.*)?$", re.IGNORECASE),
        "Hard Deny: 'gcloud organizations add-iam-policy-binding' is prohibited by workspace policy.",
    ),
    (
        re.compile(r"^gcloud\s+organizations\s+remove-iam-policy-binding(?:\s+.*)?$", re.IGNORECASE),
        "Hard Deny: 'gcloud organizations remove-iam-policy-binding' is prohibited by workspace policy.",
    ),
    (
        re.compile(r"^gcloud\s+projects\s+delete(?:\s+.*)?$", re.IGNORECASE),
        "Hard Deny: 'gcloud projects delete' is prohibited by workspace policy.",
    ),
    (
        re.compile(r"^gcloud\s+resource-manager\s+folders\s+delete(?:\s+.*)?$", re.IGNORECASE),
        "Hard Deny: 'gcloud resource-manager folders delete' is prohibited by workspace policy.",
    ),
]

# Allowed command patterns (migrated from .claude/settings.json)
ALLOW_COMMAND_PATTERNS: List[re.Pattern[str]] = [
    re.compile(r"^gcloud\s+config\s+list(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+config\s+get(?:-value)?(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+config\s+configurations\s+list(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+--version$"),
    re.compile(r"^gcloud\s+org-policies\s+describe(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+org-policies\s+list(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+projects\s+describe(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+projects\s+list(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+projects\s+get-ancestors-iam-policy(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+resource-manager\s+folders\s+describe(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+resource-manager\s+folders\s+list(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+asset\s+analyze-iam-policy(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+asset\s+search-all-iam-policies(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+asset\s+search-all-resources(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+access-context-manager\s+perimeters\s+describe(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+access-context-manager\s+perimeters\s+list(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+logging\s+read(?:\s+.*)?$"),
    re.compile(r"^gcloud\s+logging\s+buckets\s+describe(?:\s+.*)?$"),
    re.compile(r"^terraform(?:\s+-chdir=\S+)?\s+fmt(?:\s+.*)?$"),
    re.compile(r"^terraform(?:\s+-chdir=\S+)?\s+validate(?:\s+.*)?$"),
    re.compile(r"^terraform\s+version$"),
    re.compile(r"^bash\s+-n(?:\s+.*)?$"),
    re.compile(r"^shellcheck(?:\s+.*)?$"),
    re.compile(r"^jq(?:\s+.*)?$"),
    re.compile(r"^python3\s+tools/redact\.py(?:\s+.*)?$"),
    re.compile(r"^python3\s+tools/test_redact\.py(?:\s+.*)?$"),
    re.compile(r"^python3\s+\.agents/scripts/test_permission_gate\.py(?:\s+.*)?$"),
    re.compile(r"^git\s+status(?:\s+.*)?$"),
    re.compile(r"^git\s+diff(?:\s+.*)?$"),
    re.compile(r"^git\s+log(?:\s+.*)?$"),
    re.compile(r"^git\s+add(?:\s+.*)?$"),
    re.compile(r"^git\s+commit(?:\s+.*)?$"),
]

SENSITIVE_SHELL_PATH_RE = re.compile(
    r"(?:^|[/\s\"'=])\.config/gcloud\b|"
    r"(?:^|[/\s\"'=])\.lzv-redaction-map\.json\b",
    re.IGNORECASE,
)


def is_denied_path(raw_path: str) -> Tuple[bool, str]:
    """Check if a file/directory path matches Read deny patterns."""
    if not raw_path:
        return False, ""

    expanded = os.path.expanduser(os.path.expandvars(raw_path.strip()))
    try:
        resolved = Path(expanded).resolve()
    except Exception:
        resolved = Path(expanded)

    home = Path.home().resolve()
    gcloud_config_dir = home / ".config" / "gcloud"
    redaction_map = home / ".lzv-redaction-map.json"

    for candidate in (resolved, Path(expanded)):
        if candidate == gcloud_config_dir or gcloud_config_dir in candidate.parents:
            return True, "Hard Deny: Reading ~/.config/gcloud/** is prohibited by workspace policy."
        if candidate == redaction_map or candidate.name == ".lzv-redaction-map.json":
            return True, "Hard Deny: Reading ~/.lzv-redaction-map.json is prohibited by workspace policy."

    return False, ""


def extract_all_commands(raw_cmd: str) -> List[str]:
    """Extract root command and any embedded subshell/eval commands."""
    commands: List[str] = [raw_cmd]
    seen: Set[str] = set()
    to_process = [raw_cmd]

    while to_process:
        curr = to_process.pop(0)
        if curr in seen:
            continue
        seen.add(curr)

        for m in re.finditer(r"""(?:bash|sh|zsh)\s+(?:-[a-zA-Z0-9]*c\s+)(?:["'])(.*?)(?:["'])""", curr):
            inner = m.group(1).strip()
            if inner and inner not in seen:
                commands.append(inner)
                to_process.append(inner)

        for m in re.finditer(r"""\$\((.*?)\)""", curr):
            inner = m.group(1).strip()
            if inner and inner not in seen:
                commands.append(inner)
                to_process.append(inner)

        for m in re.finditer(r"""`([^`]+)`""", curr):
            inner = m.group(1).strip()
            if inner and inner not in seen:
                commands.append(inner)
                to_process.append(inner)

    return commands


def normalize_segment(seg: str) -> str:
    """Normalize a command segment by collapsing whitespace and stripping prefixes."""
    s = re.sub(r"\s+", " ", seg).strip()
    changed = True
    while changed:
        before = s
        s = re.sub(r"^(?:nohup|time|env)\s+", "", s)
        s = re.sub(r"^[A-Za-z_][A-Za-z0-9_]*=(?:\"[^\"]*\"|'[^']*'|\S*)\s+", "", s)
        s = s.strip()
        changed = s != before
    return s


def evaluate_command(command_line: str) -> Dict[str, Any]:
    """Evaluate a shell command against deny and allow lists."""
    raw_cmd = command_line.strip()
    if not raw_cmd:
        return {"decision": "ask", "reason": "Empty command requires confirmation."}

    if SENSITIVE_SHELL_PATH_RE.search(raw_cmd):
        return {
            "decision": "deny",
            "reason": "Hard Deny: Accessing ~/.config/gcloud/** or ~/.lzv-redaction-map.json is prohibited.",
        }

    all_commands = extract_all_commands(raw_cmd)
    segments: List[str] = []
    for cmd in all_commands:
        for seg in re.split(r";|&&|\|\||\||\n", cmd):
            norm = normalize_segment(seg)
            if norm:
                segments.append(norm)

    if not segments:
        return {"decision": "ask", "reason": "Command requires confirmation."}

    all_allowed = True
    for seg in segments:
        for pattern, reason in DENY_COMMAND_PATTERNS:
            if pattern.search(seg):
                return {"decision": "deny", "reason": reason}

        if not any(pat.search(seg) for pat in ALLOW_COMMAND_PATTERNS):
            all_allowed = False

    if all_allowed:
        return {"decision": "allow", "reason": "Allowed by workspace permission policy."}

    return {
        "decision": "ask",
        "reason": "Command is not in the workspace auto-allow list; requires human approval.",
    }


def evaluate_tool_call(input_data: Dict[str, Any]) -> Dict[str, Any]:
    """Evaluate a PreToolUse payload."""
    tool_call = input_data.get("toolCall", {})
    name = tool_call.get("name", "")
    args = tool_call.get("args", {}) or {}

    if name == "run_command":
        cmd = args.get("CommandLine") or args.get("command") or ""
        return evaluate_command(str(cmd))

    if name in ("view_file", "read_file", "grep_search", "find_by_name", "list_dir"):
        for key in ("Path", "AbsolutePath", "SearchPath", "DirectoryPath", "TargetFile", "path"):
            val = args.get(key)
            if isinstance(val, str):
                denied, reason = is_denied_path(val)
                if denied:
                    return {"decision": "deny", "reason": reason}
            elif isinstance(val, list):
                for item in val:
                    if isinstance(item, str):
                        denied, reason = is_denied_path(item)
                        if denied:
                            return {"decision": "deny", "reason": reason}
        return {"decision": "allow", "reason": "Path allowed by workspace policy."}

    return {"decision": "ask", "reason": f"Tool '{name}' subject to user permission grants."}


def main() -> int:
    try:
        raw = sys.stdin.read()
        payload = json.loads(raw) if raw.strip() else {}
    except Exception:
        payload = {}

    result = evaluate_tool_call(payload)
    sys.stdout.write(json.dumps(result) + "\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
