#!/usr/bin/env python3
"""Offline, end-to-end release-listing regression tests (standard library only)."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
API_PATH = "repos/pingdotgg/t3code/releases"
MOCK_API = r'''
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["MOCK_ROOT"])
if Path(sys.argv[0]).name == "sleep":
    with (root / "sleeps").open("a") as log:
        log.write(sys.argv[1] + "\n")
    sys.exit(0)
path = sys.argv[-1].removeprefix("https://api.github.com/")
log = root / "requests"
previous = log.read_text().splitlines() if log.exists() else []
with log.open("a") as handle:
    handle.write(path + "\n")
responses = json.loads((root / "responses.json").read_text()).get(path)
if responses is None:
    print("unexpected request: " + path, file=sys.stderr)
    sys.exit(99)
response = responses[min(previous.count(path), len(responses) - 1)]
sys.stdout.write(response["body"])
sys.stderr.write(response.get("error", ""))
sys.exit(response.get("code", 0))
'''


def release(version, *, prerelease=False, draft=False, published="2026-10-23T00:00:00Z", complete=True):
    names = [f"T3-Code-{version}-x86_64.AppImage", f"T3-Code-{version}-arm64.zip", f"T3-Code-{version}-x64.zip"]
    return {
        "tag_name": "v" + version,
        "prerelease": prerelease,
        "draft": draft,
        "published_at": published,
        "assets": [{"name": name, "digest": "sha256:" + "a" * 64} for name in (names if complete else names[:1])],
    }


def nightlies(count=5):
    return [release(f"1.0.0-nightly.{i}", prerelease=True, published=f"2026-10-23T00:{i % 60:02}:00Z") for i in range(count)]


def stable_releases(count=5):
    return [release(f"1.0.{i}", published=f"2026-10-22T00:{i % 60:02}:00Z") for i in range(count)]


def response(body, code=0, error=""):
    return {"body": body if isinstance(body, str) else json.dumps(body), "code": code, "error": error}


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        shutil.copyfile(ROOT / "scripts/update.sh", self.root / "scripts/update.sh")
        self.original = {"channels": {c: {"version": "old", "assets": {}} for c in ("stable", "nightly")}}
        (self.root / "sources.json").write_text(json.dumps(self.original))
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for command in ("bash", "dirname", "mktemp", "rm", "mv", "jq"):
            executable = shutil.which(command)
            self.assertIsNotNone(executable, f"missing test dependency: {command}")
            (self.bin / command).symlink_to(executable)
        self.responses = {}
        self.tmp = self.root / "tmp"
        self.tmp.mkdir()

    def page(self, per_page, page, *responses):
        self.responses[f"{API_PATH}?per_page={per_page}&page={page}"] = list(responses)

    def run_update(self, *channels, transport="gh"):
        for name in ("curl", "sleep", *( ["gh"] if transport == "gh" else [] )):
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\n" + MOCK_API)
            path.chmod(0o755)
        (self.root / "responses.json").write_text(json.dumps(self.responses))
        env = dict(os.environ, PATH=str(self.bin), TMPDIR=str(self.tmp), MOCK_ROOT=str(self.root))
        result = subprocess.run([str(self.bin / "bash"), str(self.root / "scripts/update.sh"), *channels], env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(list(self.tmp.iterdir()), [], "release-listing temporary files leaked")
        return result

    def requests(self):
        path = self.root / "requests"
        return path.read_text().splitlines() if path.exists() else []

    def request_count(self, per_page, page):
        return self.requests().count(f"{API_PATH}?per_page={per_page}&page={page}")

    def sources(self):
        return json.loads((self.root / "sources.json").read_text())

    def assert_failed(self, result, message):
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(message, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.sources(), self.original)

    def test_default_channels_keep_selection_and_output(self):
        self.page(100, 1, response(stable_releases() + nightlies()))
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "stable 1.0.4\nnightly 1.0.0-nightly.4\n")
        self.assertEqual(self.request_count(100, 1), 2)

    def test_channel_filters_and_incomplete_assets(self):
        data = nightlies()
        data[-1]["assets"] = []
        data += [release("9.9.9", published="2027-01-01T00:00:00Z"), release("9.9.9-beta", prerelease=True), release("9.9.9-nightly.0", prerelease=True, draft=True)]
        self.page(100, 1, response(data))
        result = self.run_update("nightly")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "nightly 1.0.0-nightly.3\n")
        self.assertIn("skipping v1.0.0-nightly.4: missing assets:", result.stderr)
        self.assertEqual(self.sources()["channels"]["stable"], self.original["channels"]["stable"])

    def test_transient_empty_page_retries_before_fallback(self):
        self.page(100, 1, response([]), response(nightlies()))
        result = self.run_update("nightly")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.request_count(100, 1), 2)
        self.assertEqual(len(self.requests()), 2)
        self.assertEqual((self.root / "sleeps").read_text(), "1\n")

    def test_transient_transport_errors_recover(self):
        self.page(100, 1, response("", 22, "HTTP 502\n"), response("", 1, "connection reset\n"), response(nightlies()))
        result = self.run_update("nightly")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HTTP 502", result.stderr)
        self.assertEqual((self.root / "sleeps").read_text(), "1\n2\n")

    def test_exhausted_errors_do_not_become_empty_results(self):
        self.page(100, 1, response("", 22, "HTTP 403: rate limit\n"))
        result = self.run_update("nightly")
        self.assert_failed(result, "could not fetch a valid release list")
        self.assertIn("HTTP 403: rate limit", result.stderr)
        self.assertEqual(len(self.requests()), 3)
        self.assertNotIn("no nightly releases", result.stderr)

    def test_empty_then_error_does_not_trigger_fallback(self):
        self.page(100, 1, response([]), response([]), response("", 1, "HTTP 503\n"))
        result = self.run_update("nightly")
        self.assert_failed(result, "could not fetch a valid release list")
        self.assertEqual(len(self.requests()), 3)

    def test_malformed_json_can_recover(self):
        self.page(100, 1, response("{truncated"), response(nightlies()))
        result = self.run_update("nightly")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("invalid release list", result.stderr)

    def test_invalid_response_shapes_fail(self):
        for value in ('{"message":"API error"}', "", "null", "[]\n[]"):
            with self.subTest(body=value):
                self.page(100, 1, response(value))
                result = self.run_update("nightly")
                self.assert_failed(result, "invalid release list")
                self.assertNotIn("no nightly releases", result.stderr)
                # Reset mock logs for the next independent attempt.
                (self.root / "requests").unlink()
                (self.root / "sleeps").unlink()

    def test_empty_large_page_uses_smaller_page(self):
        self.page(100, 1, response([]))
        self.page(10, 1, response(nightlies()))
        result = self.run_update("nightly")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.request_count(100, 1), 3)
        self.assertEqual(self.request_count(10, 1), 1)
        self.assertIn("trying 10 releases per page at offset 0", result.stderr)

    def test_no_releases_still_fails_after_bounded_attempts(self):
        self.page(100, 1, response([]))
        self.page(10, 1, response([]))
        result = self.run_update("nightly")
        self.assert_failed(result, "no nightly releases found")
        self.assertEqual(len(self.requests()), 6)

    def test_fallback_failure_is_not_hidden(self):
        self.page(100, 1, response([]))
        self.page(10, 1, response("", 22, "HTTP 500\n"))
        result = self.run_update("nightly")
        self.assert_failed(result, "could not fetch a valid release list")
        self.assertEqual(len(self.requests()), 6)

    def test_no_matching_channel_still_fails(self):
        self.page(100, 1, response(stable_releases()))
        self.page(100, 2, response([]))
        self.page(10, 11, response([]))
        result = self.run_update("nightly")
        self.assert_failed(result, "no nightly releases found")
        self.assertEqual(len(self.requests()), 7)

    def test_fallback_preserves_offset_and_existing_candidates(self):
        older = release("0.9.0", published="2026-01-01T00:00:00Z")
        self.page(100, 1, response(nightlies(99) + [older]))
        self.page(100, 2, response([]))
        self.page(10, 11, response(stable_releases(4)))
        result = self.run_update("stable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "stable 1.0.3\n")
        self.assertEqual(self.request_count(10, 11), 1)
        self.assertEqual(len(self.requests()), 5)

    def test_later_fetch_error_does_not_use_older_candidates(self):
        self.page(100, 1, response(nightlies(99) + [release("0.9.0")]))
        self.page(100, 2, response("", 22, "HTTP 502\n"))
        result = self.run_update("stable")
        self.assert_failed(result, "could not fetch a valid release list")
        self.assertEqual(len(self.requests()), 4)

    def test_small_pages_keep_deep_stable_search(self):
        self.page(100, 1, response([]))
        for page in range(1, 16):
            self.page(10, page, response(nightlies(10)))
        self.page(10, 16, response(stable_releases()))
        result = self.run_update("stable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "stable 1.0.4\n")
        self.assertEqual(len(self.requests()), 19)

    def test_small_page_search_stops_at_500_releases(self):
        self.page(100, 1, response([]))
        for page in range(1, 51):
            self.page(10, page, response(nightlies(10)))
        result = self.run_update("stable")
        self.assert_failed(result, "no stable releases found")
        self.assertEqual(len(self.requests()), 53)
        self.assertEqual(self.request_count(10, 50), 1)

    def test_large_page_pagination_keeps_original_bound(self):
        for page in range(1, 6):
            self.page(100, page, response(nightlies(100)))
        result = self.run_update("stable")
        self.assert_failed(result, "no stable releases found")
        self.assertEqual(len(self.requests()), 5)

    def test_late_fallback_stops_at_original_bound(self):
        for page in range(1, 5):
            self.page(100, page, response(nightlies(100)))
        self.page(100, 5, response([]))
        for page in range(41, 51):
            self.page(10, page, response(nightlies(10)))
        result = self.run_update("stable")
        self.assert_failed(result, "no stable releases found")
        self.assertEqual(len(self.requests()), 17)
        self.assertEqual(self.request_count(10, 41), 1)
        self.assertEqual(self.request_count(10, 50), 1)

    def test_stable_release_on_last_small_page_is_found(self):
        for page in range(1, 5):
            self.page(100, page, response(nightlies(100)))
        self.page(100, 5, response([]))
        for page in range(41, 50):
            self.page(10, page, response(nightlies(10)))
        self.page(10, 50, response(nightlies(9) + [release("1.0.0")]))
        result = self.run_update("stable")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "stable 1.0.0\n")
        self.assertEqual(len(self.requests()), 17)

    def test_malformed_release_record_fails_without_updating(self):
        self.page(100, 1, response([{"prerelease": True, "tag_name": "v1-nightly.0"}]))
        result = self.run_update("nightly")
        self.assert_failed(result, "malformed release data")
        self.assertEqual(len(self.requests()), 1)

    def test_all_incomplete_releases_still_fail(self):
        data = nightlies()
        for item in data:
            item["assets"] = []
        self.page(100, 1, response(data))
        result = self.run_update("nightly")
        self.assert_failed(result, "no nightly release has assets for all supported systems")

    def test_up_to_date_remains_silent(self):
        self.original["channels"]["nightly"]["version"] = "1.0.0-nightly.4"
        (self.root / "sources.json").write_text(json.dumps(self.original))
        self.page(100, 1, response(nightlies()))
        result = self.run_update("nightly")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.sources(), self.original)

    def test_curl_transport_has_same_retry_and_fallback_behavior(self):
        self.page(100, 1, response([]))
        self.page(10, 1, response("", 22, "HTTP 502\n"), response(nightlies()))
        result = self.run_update("nightly", transport="curl")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "nightly 1.0.0-nightly.4\n")
        self.assertEqual(len(self.requests()), 5)

    def test_unknown_channel_fails_before_network(self):
        result = self.run_update("beta")
        self.assert_failed(result, "unknown channel")
        self.assertEqual(self.requests(), [])


if __name__ == "__main__":
    unittest.main()
