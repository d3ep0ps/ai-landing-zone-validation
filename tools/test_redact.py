#!/usr/bin/env python3
"""Unit tests for redact.py, using synthetic IDs only. Run: python3 -m unittest tools/test_redact.py"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import redact  # noqa: E402

FAKE_ORG = "111122223333"
CONFIG = {"org_id": FAKE_ORG, "project_ids": ["fake-ai-prj-01", "fake-ai-prj-02"], "domain": "fakecorp.test"}

SAMPLE = f"""parent: organizations/{FAKE_ORG}
orgId: {FAKE_ORG}
folder: folders/444455556666
project: projects/777788889999 (fake-ai-prj-01)
other: projects/123456789012/locations/europe-west1
agent: service-777788889999@gcp-sa-aiplatform.iam.gserviceaccount.com
compute: 777788889999-compute@developer.gserviceaccount.com
sa: runner-sa@fake-ai-prj-02.iam.gserviceaccount.com
user: alice@fakecorp.test and Bob@FakeCorp.TEST
billing: 0A1B2C-3D4E5F-6A7B8C
token: ya29.a0AfH6SMfakefakefake_123
number again: 777788889999
not a project: fake-ai-prj-010
"""


class RedactTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.cfg = self.tmp / "cfg.json"
        self.cfg.write_text(json.dumps(CONFIG))
        self.map = self.tmp / "map.json"
        self.ev = self.tmp / "evidence"
        self.ev.mkdir()
        (self.ev / "a.txt").write_text(SAMPLE)
        (self.ev / "b.txt").write_text("again projects/777788889999 and alice@fakecorp.test\n")
        (self.ev / "bin.dat").write_bytes(b"\0\x01projects/777788889999")

    def run_redact(self, *extra):
        return redact.main([*extra, "--config", str(self.cfg), "--map", str(self.map), str(self.ev)])

    def test_redacts_all_patterns(self):
        rc = self.run_redact()
        self.assertEqual(rc, 3, "token present -> incident exit code")
        out = (self.ev / "a.txt").read_text()
        for real in [FAKE_ORG, "444455556666", "777788889999", "123456789012", "fake-ai-prj-01\n",
                     "runner-sa", "alice", "Bob@", "fakecorp.test", "0A1B2C", "ya29."]:
            self.assertNotIn(real.lower(), out.lower(), real)
        self.assertIn("organizations/ORG_ID", out)
        self.assertIn("orgId: ORG_ID", out)
        self.assertIn("folders/FOLDER_ID_1", out)
        self.assertIn("projects/PROJECT_NUMBER_1 (PROJECT_1)", out)
        self.assertIn("service-PROJECT_NUMBER_1@gcp-sa-aiplatform.iam.gserviceaccount.com", out)
        self.assertIn("PROJECT_NUMBER_1-compute@developer.gserviceaccount.com", out)
        self.assertIn("SA_1@PROJECT.iam.gserviceaccount.com", out)
        self.assertIn("USER_1@example.com and USER_2@example.com", out)
        self.assertIn("BILLING_ACCOUNT", out)
        self.assertIn("REDACTED_TOKEN", out)
        self.assertIn("number again: PROJECT_NUMBER_1", out)
        self.assertIn("not a project: fake-ai-prj-010", out, "partial project ID must not match")

    def test_consistent_across_files_and_runs(self):
        self.run_redact()
        self.assertEqual((self.ev / "b.txt").read_text(),
                         "again projects/PROJECT_NUMBER_1 and USER_1@example.com\n")
        (self.ev / "c.txt").write_text("projects/123456789012 alice@fakecorp.test\n")
        self.run_redact()
        self.assertEqual((self.ev / "c.txt").read_text(), "projects/PROJECT_NUMBER_2 USER_1@example.com\n")

    def test_skips_binary(self):
        self.run_redact()
        self.assertIn(b"777788889999", (self.ev / "bin.dat").read_bytes())

    def test_check_mode(self):
        self.assertEqual(self.run_redact("--check"), 1, "unredacted files must fail check")
        self.run_redact()
        self.assertEqual(self.run_redact("--check"), 0, "redacted files must pass check")
        self.assertEqual((self.ev / "a.txt").read_text().count("ORG_ID"), 2)

    def test_map_written_outside_repo_with_real_values(self):
        self.run_redact()
        m = json.loads(self.map.read_text())
        self.assertEqual(m["project_number"]["777788889999"], "PROJECT_NUMBER_1")
        self.assertEqual(oct(self.map.stat().st_mode & 0o777), "0o600")

    def test_extra_ids(self):
        (self.ev / "e.txt").write_text(
            "name: accessPolicies/900011112222/servicePerimeters/lzv_ai\n"
            "cmd: perimeters describe lzv_ai --policy=900011112222 --format=json\n"
            "file: 21-perimeters-900011112222.txt\n"
            "id: projects/777788889999/locations/europe-west1/reasoningEngines/5550001112223334445\n"
            "engine id: 5550001112223334445\n"
            "sa: projects/-/serviceAccounts/104455667788990011223\n"
            "\"oauthClientId\": \"32555000111.apps.googleusercontent.com\"\n"
            "uniqueId: '104455667788990011223'\n"
            "ts: 1761369600.123 gen: probe.txt#1761369600123456\n")
        self.assertEqual(self.run_redact("--check"), 1)
        self.run_redact()
        out = (self.ev / "e.txt").read_text()
        for real in ["900011112222", "5550001112223334445", "104455667788990011223", "32555000111"]:
            self.assertNotIn(real, out, real)
        self.assertIn("accessPolicies/ACCESS_POLICY_1/servicePerimeters", out)
        self.assertIn("--policy=ACCESS_POLICY_1 ", out)
        self.assertIn("21-perimeters-ACCESS_POLICY_1.txt", out)
        self.assertIn("reasoningEngines/AGENT_ID_1\nengine id: AGENT_ID_1", out)
        self.assertIn("serviceAccounts/SA_UNIQUE_ID_1", out)
        self.assertIn("uniqueId: 'SA_UNIQUE_ID_1'", out)
        self.assertIn("\"oauthClientId\": \"SA_UNIQUE_ID_2.apps.googleusercontent.com\"", out)
        self.assertIn("ts: 1761369600.123 gen: probe.txt#1761369600123456", out, "timestamps stay")
        self.assertEqual(self.run_redact("--check"), 0)

    def test_ansi_home_ip(self):
        (self.ev / "f.txt").write_text(
            "in project [\x1b[1mfake-ai-prj-01\x1b[m] region\n"
            "$ gcloud builds submit /Users/somebody/Projects/x --config=/Users/somebody/x.yaml\n"
            "\"callerIp\": \"198.51.100.23\", private 10.0.0.1, doc 203.0.113.5, ver 300.1.2.3\n")
        self.assertEqual(self.run_redact("--check"), 1)
        self.run_redact()
        out = (self.ev / "f.txt").read_text()
        self.assertIn("[\x1b[1mPROJECT_1\x1b[m]", out)
        self.assertIn("/Users/USER/Projects/x --config=/Users/USER/x.yaml", out)
        self.assertIn("\"callerIp\": \"IP_1\", private 10.0.0.1, doc 203.0.113.5, ver 300.1.2.3", out)
        self.assertEqual(self.run_redact("--check"), 0)

    def test_keep_domain(self):
        (self.ev / "d.txt").write_text("org fakecorp.test\n")
        self.run_redact("--keep-domain")
        self.assertEqual((self.ev / "d.txt").read_text(), "org fakecorp.test\n")


if __name__ == "__main__":
    unittest.main()
