#!/usr/bin/env python3
import os
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts"))
import release_info  # noqa: E402

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "scripts", "release_info.py")


class ReleaseInfo(unittest.TestCase):
    def test_example_from_the_card(self):
        self.assertEqual(release_info.compute("2026-11-24T10:33:17Z"), ("2026.1124.103317", "v2026.1124.103317"))

    def test_converts_to_utc(self):
        # 21:36:07 in UTC+8 is 13:36:07 UTC.
        self.assertEqual(release_info.compute("2026-11-24T21:36:07+08:00")[0], "2026.1124.133607")
        # A different local day: 02:00 in UTC+8 is the previous day in UTC.
        self.assertEqual(release_info.compute("2026-11-25T02:00:00+08:00")[0], "2026.1124.180000")

    def test_month_is_unpadded_day_is_padded(self):
        self.assertEqual(release_info.compute("2026-01-05T12:00:00Z")[0], "2026.105.120000")
        self.assertEqual(release_info.compute("2026-09-30T12:00:00Z")[0], "2026.930.120000")
        self.assertEqual(release_info.compute("2026-10-01T12:00:00Z")[0], "2026.1001.120000")

    def test_clock_loses_leading_zeros(self):
        self.assertEqual(release_info.compute("2026-11-24T00:00:05Z")[0], "2026.1124.5")
        self.assertEqual(release_info.compute("2026-11-24T00:10:05Z")[0], "2026.1124.1005")

    def test_versions_increase_with_time(self):
        stamps = ["2026-09-30T23:59:59Z", "2026-10-01T00:00:00Z", "2026-11-24T10:33:17Z", "2026-12-31T23:59:59Z", "2027-01-01T00:00:00Z"]
        versions = [tuple(int(p) for p in release_info.compute(s)[0].split(".")) for s in stamps]
        self.assertEqual(versions, sorted(versions))
        self.assertEqual(len(set(versions)), len(versions))

    def test_tag_pattern(self):
        for ok in ("v2026.1124.103317", "v2026.105.120000", "v2026.1124.5"):
            self.assertTrue(release_info.is_timestamp_tag(ok), ok)
        for bad in ("v1.3.9", "v1.3.9-rc.10", "v2026.1124", "v2026.12.5", "v2026.1124.1033170", "2026.1124.103317", "v26.1124.5"):
            self.assertFalse(release_info.is_timestamp_tag(bad), bad)

    def test_computed_tags_match_the_pattern(self):
        for iso in ("2026-01-05T00:00:05Z", "2026-10-31T23:59:59Z", "2026-11-24T10:33:17Z"):
            self.assertTrue(release_info.is_timestamp_tag(release_info.compute(iso)[1]))

    def test_check_tag(self):
        def run(*args):
            return subprocess.run([sys.executable, SCRIPT, *args], capture_output=True, text=True).returncode
        d = "2026-11-24T10:33:17Z"
        self.assertEqual(run("--date", d, "--check-tag", "v2026.1124.103317"), 0)
        self.assertEqual(run("--date", d, "--check-tag", "v2026.1124.103318"), 1)
        self.assertEqual(run("--date", d, "--check-tag", "v1.3.9"), 1)

    def test_check_tag_from_the_repository(self):
        """Without --date, as in CI: the committer date of the checked-out commit, for lightweight and annotated tags."""
        import tempfile
        commit_time = "2026-11-24T10:33:17+00:00"
        env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
               "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid",
               "GIT_AUTHOR_DATE": "2026-01-02T03:04:05+00:00", "GIT_COMMITTER_DATE": commit_time}
        with tempfile.TemporaryDirectory() as repo:
            def git(*args, **extra):
                subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True, env={**env, **extra})
            def check(tag):
                return subprocess.run([sys.executable, SCRIPT, "--check-tag", tag], cwd=repo, capture_output=True).returncode
            git("init", "-q")
            git("commit", "-q", "--allow-empty", "-m", "c")
            # The annotated tag's own date differs from the commit's committer date and must not count.
            git("tag", "-a", "-m", "m", "v2026.1124.103317", GIT_COMMITTER_DATE="2026-12-31T23:59:59+00:00")
            self.assertEqual(check("v2026.1124.103317"), 0)
            self.assertEqual(check("v2026.1124.103318"), 1)
            self.assertEqual(check("v2026.1231.235959"), 1)
            git("tag", "-d", "v2026.1124.103317")
            git("tag", "v2026.1124.103317")
            self.assertEqual(check("v2026.1124.103317"), 0)
            self.assertEqual(check("v1.3.9"), 1)


if __name__ == "__main__":
    unittest.main()
