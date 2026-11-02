#!/usr/bin/env python3
"""Unit tests for .agents/scripts/permission_gate.py."""

import unittest
from permission_gate import evaluate_tool_call


class PermissionGateTest(unittest.TestCase):
    def _run_cmd(self, cmd: str) -> str:
        res = evaluate_tool_call({"toolCall": {"name": "run_command", "args": {"CommandLine": cmd}}})
        return res["decision"]

    def _read_path(self, path: str) -> str:
        res = evaluate_tool_call({"toolCall": {"name": "view_file", "args": {"Path": path}}})
        return res["decision"]

    def test_allowed_commands(self) -> None:
        allowed = [
            "gcloud config list --format=json",
            "gcloud config get project",
            "gcloud config configurations list --filter=is_active:true",
            "gcloud --version",
            "gcloud org-policies describe iam.disableServiceAccountKeyCreation --folder=FOLDER_ID_1",
            "gcloud org-policies list --folder=FOLDER_ID_1",
            "gcloud projects describe my-proj",
            "gcloud projects list --filter=parent.id:FOLDER_ID_1",
            "gcloud projects get-ancestors-iam-policy my-proj",
            "gcloud resource-manager folders describe FOLDER_ID_1",
            "gcloud resource-manager folders list --organization=ORGANIZATION_ID",
            "gcloud asset analyze-iam-policy --organization=ORGANIZATION_ID",
            "gcloud asset search-all-iam-policies --scope=folders/FOLDER_ID_1",
            "gcloud asset search-all-resources --scope=folders/FOLDER_ID_1",
            "gcloud access-context-manager perimeters describe my-perim",
            "gcloud access-context-manager perimeters list --policy=ACCESS_POLICY_1",
            "gcloud logging read 'logName:cloudaudit' --limit=10",
            "gcloud logging buckets describe _Default --location=global",
            "terraform fmt -check infra/",
            "terraform validate",
            "terraform version",
            "bash -n tests/T01.sh",
            "shellcheck tests/T01.sh",
            "jq .verdict evidence/T01/result.json",
            "python3 tools/redact.py --check evidence",
            "python3 tools/test_redact.py",
            "git status -s",
            "git diff HEAD",
            "git log -n 5",
            "git add PROGRESS.md",
            "git commit -m 'Phase 1 complete'",
        ]
        for cmd in allowed:
            with self.subTest(cmd=cmd):
                self.assertEqual(self._run_cmd(cmd), "allow")

    def test_denied_commands(self) -> None:
        denied = [
            "git push origin main",
            "git push",
            "gcloud organizations set-iam-policy ORGANIZATION_ID policy.json",
            "gcloud organizations add-iam-policy-binding ORGANIZATION_ID --member=user:USER_1@example.com --role=roles/owner",
            "gcloud organizations remove-iam-policy-binding ORGANIZATION_ID --member=user:USER_1@example.com --role=roles/owner",
            "gcloud projects delete my-proj",
            "gcloud resource-manager folders delete FOLDER_ID_1",
            "git status && git push",
            "cat ~/.config/gcloud/credentials.db",
            "jq . ~/.lzv-redaction-map.json",
        ]
        for cmd in denied:
            with self.subTest(cmd=cmd):
                self.assertEqual(self._run_cmd(cmd), "deny")

    def test_ask_commands(self) -> None:
        ask = [
            "bash tests/T01.sh",
            "terraform apply",
            "gcloud run services create test-svc --image=us-docker.pkg.dev/cloudrun/container/hello",
        ]
        for cmd in ask:
            with self.subTest(cmd=cmd):
                self.assertEqual(self._run_cmd(cmd), "ask")

    def test_read_file_permissions(self) -> None:
        self.assertEqual(self._read_path("~/.config/gcloud/configurations/config_default"), "deny")
        self.assertEqual(self._read_path("~/.lzv-redaction-map.json"), "deny")
        self.assertEqual(self._read_path("EXECUTION-PLAN.md"), "allow")


if __name__ == "__main__":
    unittest.main()
