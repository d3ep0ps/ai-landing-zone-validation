#!/usr/bin/env python3
"""Redact GCP identifiers and secrets from evidence files (EXECUTION-PLAN.md Appendix B).

Usage:
  redact.py [--config FILE] [--map FILE] [--keep-domain] PATH...   rewrite files in place
  redact.py --check [--config FILE] PATH...                        exit 1 if anything is left

Config (JSON, kept outside the repo, default ~/.lzv-redaction-config.json):
  {"org_id": "123...", "project_ids": ["my-proj"], "domain": "corp.example"}

The mapping (real value -> placeholder) is written to ~/.lzv-redaction-map.json
(or --map / $LZV_REDACTION_MAP). It is loaded on start, so placeholders stay the
same across runs. Never commit it.
"""
import argparse
import json
import os
import re
import sys
from pathlib import Path

DEFAULT_CONFIG = Path(os.environ.get("LZV_REDACTION_CONFIG", "~/.lzv-redaction-config.json")).expanduser()
DEFAULT_MAP = Path(os.environ.get("LZV_REDACTION_MAP", "~/.lzv-redaction-map.json")).expanduser()
SKIP_DIRS = {".git", ".terraform", "vendor", "__pycache__"}

TOKEN_RE = re.compile(r"ya29\.[0-9A-Za-z_\-\.]+")
# Google error IDs (Policy Troubleshooter errorId / ErrorInfo error_info_id) are base64 and embed the
# resource path, i.e. the real project ID (found in the run-9 review). Replace the whole value.
ERRID_RE = re.compile(r"(errorId=|[\"']error_?[Ii]nfo_?[Ii]d[\"']\s*:\s*[\"'])[A-Za-z0-9+/_\-]{16,}={0,2}")
BILLING_RE = re.compile(r"\b[0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6}\b")
ORG_RE = re.compile(r"\borganizations/(\d+)")
FOLDER_RE = re.compile(r"\bfolders/(\d+)")
PROJECT_NUM_RE = re.compile(r"\bprojects/(\d+)")
# Service agents and default SAs that embed a project number.
AGENT_NUM_RES = [
    re.compile(r"\bservice-(\d+)@"),
    re.compile(r"\b(\d+)-compute@developer\.gserviceaccount\.com"),
    re.compile(r"\b(\d+)@cloudservices\.gserviceaccount\.com"),
    re.compile(r"\b(\d+)@cloudbuild\.gserviceaccount\.com"),
    # Added 2026-10-28 (run-6 scan): PSC network attachment consumer (Agent Runtime tenant project).
    re.compile(r"\bprojectIdOrNum[\"']?\s*:\s*[\"']?(\d{6,})"),
]
# Added 2026-10-25 (Phase 5, human approved): IDs found in run evidence that Appendix B did not list.
ACCESS_POLICY_RES = [
    re.compile(r"\baccessPolicies/(\d+)"),
    re.compile(r"--policy[= ](\d+)\b"),
    re.compile(r"\bperimeters-(\d+)\b"),
]
AGENT_ID_RES = [
    re.compile(r"\breasoningEngines/(\d+)"),
    re.compile(r"\bengine id: (\d+)"),
]
SA_UNIQUE_RES = [
    re.compile(r"\bserviceAccounts/(\d{15,})\b"),
    re.compile(r"\b(?:uniqueId|oauth2?ClientId)[\"']?\s*[:=]\s*[\"']?(\d{6,})"),
]
# Project IDs may follow an ANSI colour code (gcloud bold output: ESC[1m).
# Project IDs also match as a name prefix (e.g. "<project>-lzv-build-cmek"); IDs are applied
# longest first, so a project ID that is a prefix of another is not split. Changed 2026-10-26 after the
# run-4 scan found a bucket name that started with the runtime project ID.
PID_PRE = r"(?:(?<![A-Za-z0-9\-])|(?<=\x1b\[1m)|(?<=\x1b\[0m)|(?<=\x1b\[m))"
HOME_RE = re.compile(r"/Users/(?!USER/)[^/\s]+/")
IPV4_RE = re.compile(r"(?<![\d.])((?:\d{1,3}\.){3}\d{1,3})(?![\d.])")
PRIVATE_IP_RE = re.compile(r"^(10\.|127\.|0\.|169\.254\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|203\.0\.113\.)")
EXTRA_KINDS = (
    ("access_policy", ACCESS_POLICY_RES, "ACCESS_POLICY_{}"),
    ("agent_id", AGENT_ID_RES, "AGENT_ID_{}"),
    ("sa_unique_id", SA_UNIQUE_RES, "SA_UNIQUE_ID_{}"),
)
SA_RE = re.compile(r"\b([a-z][a-z0-9\-]{4,29})@([a-z][a-z0-9\-]{4,29})\.iam\.gserviceaccount\.com")
EMAIL_RE = re.compile(r"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b")

# Placeholders and generic domains that may stay in published files.
EMAIL_ALLOW_RE = re.compile(
    r"(^USER_\d+@example\.com$|^SA_\d+@PROJECT\.iam\.gserviceaccount\.com$|"
    r"@example\.(com|org)$|PROJECT_NUMBER_\d+@|@gcp-sa-[a-z0-9\-]+\.iam\.gserviceaccount\.com$|"
    r"@(developer|cloudservices|cloudbuild)\.gserviceaccount\.com$|@noreply\.github\.com$|^noreply@)"
)


class Redactor:
    def __init__(self, config, mapping, keep_domain=False):
        self.org_id = str(config.get("org_id") or "")
        self.project_ids = sorted({p for p in config.get("project_ids", []) if p}, key=len, reverse=True)
        self.domain = config.get("domain") or ""  # only from the private config
        self.keep_domain = keep_domain
        kinds = ("project_number", "project", "folder", "user", "sa", "ip") + tuple(k for k, _, _ in EXTRA_KINDS)
        self.map = {k: dict(mapping.get(k, {})) for k in kinds}
        self.incidents = []

    def _ph(self, kind, value, fmt):
        table = self.map[kind]
        if value not in table:
            table[value] = fmt.format(len(table) + 1)
        return table[value]

    @staticmethod
    def _is_ip(v):
        return all(0 <= int(x) <= 255 for x in v.split("."))

    def collect(self, text):
        """First pass: assign placeholders in a stable order before rewriting."""
        for m in PROJECT_NUM_RE.finditer(text):
            self._ph("project_number", m.group(1), "PROJECT_NUMBER_{}")
        for r in AGENT_NUM_RES:
            for m in r.finditer(text):
                self._ph("project_number", m.group(1), "PROJECT_NUMBER_{}")
        for m in FOLDER_RE.finditer(text):
            self._ph("folder", m.group(1), "FOLDER_ID_{}")
        for kind, res, fmt in EXTRA_KINDS:
            for r in res:
                for m in r.finditer(text):
                    self._ph(kind, m.group(1), fmt)
        if self.project_ids:
            alt = "|".join(map(re.escape, self.project_ids))
            for m in re.finditer(rf"{PID_PRE}({alt})(?![A-Za-z0-9])", text):
                self._ph("project", m.group(1), "PROJECT_{}")

    def redact(self, text, source="<text>"):
        if TOKEN_RE.search(text):
            self.incidents.append(f"OAuth token found in {source}")
            text = TOKEN_RE.sub("REDACTED_TOKEN", text)
        text = ERRID_RE.sub(lambda m: m.group(1) + "REDACTED_ERROR_ID", text)
        text = BILLING_RE.sub("BILLING_ACCOUNT", text)
        text = HOME_RE.sub("/Users/USER/", text)
        text = IPV4_RE.sub(lambda m: m.group(0) if PRIVATE_IP_RE.match(m.group(1)) or not self._is_ip(m.group(1))
                           else self._ph("ip", m.group(1), "IP_{}"), text)

        for r in AGENT_NUM_RES:
            text = r.sub(lambda m: m.group(0).replace(m.group(1), self._ph("project_number", m.group(1), "PROJECT_NUMBER_{}")), text)
        text = SA_RE.sub(lambda m: self._ph("sa", m.group(0).lower(), "SA_{}") + "@PROJECT.iam.gserviceaccount.com", text)

        def user(m):
            e = m.group(0)
            if EMAIL_ALLOW_RE.search(e):
                return e
            return self._ph("user", e.lower(), "USER_{}") + "@example.com"
        text = EMAIL_RE.sub(user, text)

        text = ORG_RE.sub("organizations/ORG_ID", text)
        text = FOLDER_RE.sub(lambda m: "folders/" + self._ph("folder", m.group(1), "FOLDER_ID_{}"), text)
        text = PROJECT_NUM_RE.sub(lambda m: "projects/" + self._ph("project_number", m.group(1), "PROJECT_NUMBER_{}"), text)

        for kind, res, fmt in EXTRA_KINDS:
            for r in res:
                text = r.sub(lambda m: m.group(0).replace(m.group(1), self._ph(kind, m.group(1), fmt)), text)

        # Bare occurrences of known numbers (e.g. "projectNumber": "123").
        if self.org_id:
            text = re.sub(rf"(?<!\d){re.escape(self.org_id)}(?!\d)", "ORG_ID", text)
        for kind in ("project_number", "folder") + tuple(k for k, _, _ in EXTRA_KINDS):
            for real, ph in self.map[kind].items():
                text = re.sub(rf"(?<!\d){re.escape(real)}(?!\d)", ph, text)
        for p in self.project_ids:
            text = re.sub(rf"{PID_PRE}{re.escape(p)}(?![A-Za-z0-9])", self._ph("project", p, "PROJECT_{}"), text)

        if not self.keep_domain and self.domain:
            text = re.sub(re.escape(self.domain), "example.org", text, flags=re.IGNORECASE)
        return text

    def check(self, text):
        """Return a list of pattern names still present."""
        found = []
        if TOKEN_RE.search(text):
            found.append("oauth_token")
        if ERRID_RE.search(text) and not all(m.group(0).endswith("REDACTED_ERROR_ID") for m in ERRID_RE.finditer(text)):
            found.append("error_id")
        if BILLING_RE.search(text):
            found.append("billing_account")
        if HOME_RE.search(text):
            found.append("home_path")
        if any(self._is_ip(m.group(1)) and not PRIVATE_IP_RE.match(m.group(1)) for m in IPV4_RE.finditer(text)):
            found.append("public_ip")
        for name, r in (("organization_id", ORG_RE), ("folder_id", FOLDER_RE), ("project_number", PROJECT_NUM_RE)):
            if r.search(text):
                found.append(name)
        if any(r.search(text) for r in AGENT_NUM_RES):
            found.append("service_agent_number")
        if self.org_id and re.search(rf"(?<!\d){re.escape(self.org_id)}(?!\d)", text):
            found.append("organization_id_bare")
        for kind, res, _ in EXTRA_KINDS:
            if any(m.group(1).isdigit() for r in res for m in r.finditer(text)):
                found.append(kind)
        for kind in ("project_number", "folder") + tuple(k for k, _, _ in EXTRA_KINDS):
            if any(re.search(rf"(?<!\d){re.escape(r)}(?!\d)", text) for r in self.map[kind]):
                found.append(f"{kind}_bare")
        if any(re.search(rf"{PID_PRE}{re.escape(p)}(?![A-Za-z0-9])", text) for p in self.project_ids):
            found.append("project_id")
        if any(not EMAIL_ALLOW_RE.search(m.group(0)) for m in EMAIL_RE.finditer(text)):
            found.append("email")
        if not self.keep_domain and self.domain and self.domain.lower() in text.lower():
            found.append("domain")
        return found


def iter_files(paths):
    for p in map(Path, paths):
        if p.is_dir():
            for f in sorted(p.rglob("*")):
                if f.is_file() and not (SKIP_DIRS & set(f.parts)):
                    yield f
        elif p.is_file():
            yield p
        else:
            print(f"warning: not found: {p}", file=sys.stderr)


def read_text(path):
    data = path.read_bytes()
    if b"\0" in data[:8192]:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def load_json(path):
    return json.loads(path.read_text()) if path.exists() else {}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--check", action="store_true", help="report remaining identifiers; do not modify files")
    ap.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    ap.add_argument("--map", type=Path, default=DEFAULT_MAP)
    ap.add_argument("--keep-domain", action="store_true", help="do not replace the configured domain")
    args = ap.parse_args(argv)

    if args.map.resolve().is_relative_to(Path.cwd().resolve()) and not args.check:
        print("error: mapping file must be outside the working directory", file=sys.stderr)
        return 2

    r = Redactor(load_json(args.config), load_json(args.map), keep_domain=args.keep_domain)
    files = [(f, t) for f in iter_files(args.paths) if (t := read_text(f)) is not None]

    if args.check:
        bad = 0
        for f, t in files:
            hits = r.check(t)
            if hits:
                bad += 1
                print(f"{f}: {', '.join(hits)}")
        print(f"checked {len(files)} files, {bad} with findings", file=sys.stderr)
        return 1 if bad else 0

    for _, t in files:
        r.collect(t)
    changed = 0
    for f, t in files:
        new = r.redact(t, source=str(f))
        if new != t:
            f.write_text(new, encoding="utf-8")
            changed += 1
    args.map.write_text(json.dumps(r.map, indent=2, sort_keys=True))
    os.chmod(args.map, 0o600)
    print(f"redacted {changed}/{len(files)} files; map: {args.map}", file=sys.stderr)
    for i in r.incidents:
        print(f"INCIDENT: {i}", file=sys.stderr)
    return 3 if r.incidents else 0


if __name__ == "__main__":
    sys.exit(main())
