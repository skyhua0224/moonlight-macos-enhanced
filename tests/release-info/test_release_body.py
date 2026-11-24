#!/usr/bin/env python3
"""A timestamp test build takes the shared beta notes and compares with the tag before it."""
import importlib.util
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("build_release_body", ROOT / ".github" / "scripts" / "build_release_body.py")
body = importlib.util.module_from_spec(spec)
spec.loader.exec_module(body)


def git(repo, *args, **env):
    full = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
            "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid", **env}
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, env=full)


class ReleaseBody(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.repo = Path(self.dir.name)
        git(self.repo, "init", "-q")
        notes = self.repo / ".github" / "release-notes"
        notes.mkdir(parents=True)
        (notes / "v1.3.9.md").write_text("stable notes\n")
        (notes / "beta.md").write_text("beta notes\n")
        for index, tag in enumerate(["v1.3.9", "v2026.1124.103317"]):
            (self.repo / "f").write_text(str(index))
            git(self.repo, "add", "-A")
            git(self.repo, "commit", "-q", "-m", f"c{index}")
            git(self.repo, "tag", tag)
        (self.repo / "f").write_text("next")
        git(self.repo, "commit", "-q", "-am", "c2")
        git(self.repo, "tag", "v2026.1201.90000")
        self.saved = (body.REPO_ROOT, body.NOTES_DIR)
        body.REPO_ROOT, body.NOTES_DIR = self.repo, notes

    def tearDown(self):
        body.REPO_ROOT, body.NOTES_DIR = self.saved
        self.dir.cleanup()

    def test_previous_tag_of_a_test_build(self):
        self.assertEqual(body.get_previous_tag("v2026.1124.103317"), "v1.3.9")
        self.assertEqual(body.get_previous_tag("v2026.1201.90000"), "v2026.1124.103317")

    def test_test_build_uses_the_shared_notes(self):
        text = body.build_body("v2026.1201.90000")
        self.assertIn("beta notes", text)
        self.assertNotIn("stable notes", text)
        self.assertIn("compare/v2026.1124.103317...v2026.1201.90000", text)

    def test_stable_tag_keeps_its_own_notes(self):
        self.assertIn("stable notes", body.build_body("v1.3.9"))


if __name__ == "__main__":
    unittest.main()
