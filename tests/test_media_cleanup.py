"""Exercise cleanup with temporary files only; never scan configured media paths."""

import contextlib
import io
import os
from pathlib import Path
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest import mock

from src.utils import media_cleanup as cleanup


class CleanupTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="media-cleanup-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()

    def make_file(self, name, age=10, content=b"media"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        timestamp = time.time() - age * 86400
        os.utime(path, (timestamp, timestamp))
        return path

    def media(self, use_atime=False):
        return cleanup.find_old_media([str(self.root)], 7, use_atime)

    def test_qb_requires_both_partial_extension_and_age(self):
        for name in ("old.!qB", "old.PARTS", "old.!ut", "old.tmp", "old.partial"):
            self.make_file(name)
        self.make_file("completed.mkv")
        self.make_file("notes.txt")
        self.make_file("fresh.!qB", age=1)
        candidates = cleanup.find_qb_temp_files([str(self.root)], 7)
        self.assertEqual({c.path.name for c in candidates},
                         {"old.!qB", "old.PARTS", "old.!ut", "old.tmp", "old.partial"})

    def test_media_filter_and_oldest_first(self):
        self.make_file("old.MKV", age=20)
        self.make_file("recent.mp4", age=8)
        self.make_file("fresh.mp4", age=1)
        self.make_file("old.txt", age=30)
        self.assertEqual([c.path.name for c in self.media()], ["old.MKV", "recent.mp4"])

    def test_atime_mode_excludes_recent_access_or_modification(self):
        accessed = self.make_file("accessed.mkv")
        modified = self.make_file("modified.mkv")
        old = time.time() - 10 * 86400
        os.utime(accessed, (time.time(), old))
        os.utime(modified, (old, time.time()))
        self.assertEqual(self.media(use_atime=True), [])
        self.assertEqual([c.path for c in self.media()], [accessed])

    def test_overlapping_roots_do_not_duplicate_candidates(self):
        path = self.make_file("nested/old.mkv")
        candidates = cleanup.find_old_media([str(self.root), str(path.parent)], 7, False)
        self.assertEqual(len(candidates), 1)

    def test_symlink_files_and_directories_are_skipped(self):
        target = self.make_file("real/old.mkv")
        (self.root / "link.mkv").symlink_to(target)
        (self.root / "linked-dir").symlink_to(target.parent, target_is_directory=True)
        self.assertEqual([c.path for c in self.media()], [target])
        self.assertEqual(cleanup.find_old_media([str(self.root / "linked-dir")], 7, False), [])

    def test_junk_directories_are_skipped(self):
        self.make_file(".Trash/old.mkv")
        self.make_file("@eaDir/old.mkv")
        self.assertEqual(self.media(), [])

    def test_dry_run_does_not_delete(self):
        path = self.make_file("old.mkv")
        self.assertEqual(cleanup.process_files(self.media(), True, "test"), 5)
        self.assertTrue(path.exists())

    def test_execute_deletes_unchanged_file(self):
        path = self.make_file("old.mkv")
        self.assertEqual(cleanup.process_files(self.media(), False, "test"), 5)
        self.assertFalse(path.exists())

    def test_replaced_file_is_preserved(self):
        path = self.make_file("old.mkv")
        candidates = self.media()
        path.rename(self.root / "original")
        self.make_file("old.mkv", content=b"replacement")
        self.assertEqual(cleanup.process_files(candidates, False, "test"), 0)
        self.assertEqual(path.read_bytes(), b"replacement")

    def test_modified_file_is_preserved(self):
        path = self.make_file("old.mkv")
        candidates = self.media()
        path.write_bytes(b"resumed download")
        self.assertEqual(cleanup.process_files(candidates, False, "test"), 0)
        self.assertTrue(path.exists())

    def test_recently_accessed_file_is_preserved(self):
        path = self.make_file("old.mkv")
        candidates = self.media(use_atime=True)
        os.utime(path, (time.time(), path.stat().st_mtime))
        self.assertEqual(cleanup.process_files(candidates, False, "test"), 0)
        self.assertTrue(path.exists())

    def test_symlink_replacement_is_preserved(self):
        path = self.make_file("old.mkv")
        candidates = self.media()
        target = self.make_file("target.txt")
        path.unlink()
        path.symlink_to(target)
        self.assertEqual(cleanup.process_files(candidates, False, "test"), 0)
        self.assertTrue(path.is_symlink())
        self.assertTrue(target.exists())

    def test_replaced_parent_symlink_is_preserved(self):
        path = self.make_file("nested/old.mkv")
        candidates = self.media()
        moved = self.root / "moved"
        path.parent.rename(moved)
        path.parent.symlink_to(moved, target_is_directory=True)
        self.assertEqual(cleanup.process_files(candidates, False, "test"), 0)
        self.assertTrue(path.exists())

    def test_missing_file_does_not_abort_remaining_deletions(self):
        missing = self.make_file("missing.mkv", age=20)
        remaining = self.make_file("remaining.mkv")
        candidates = self.media()
        missing.unlink()
        self.assertEqual(cleanup.process_files(candidates, False, "test"), 5)
        self.assertFalse(remaining.exists())

    def test_age_is_rechecked_if_clock_moves_backward(self):
        path = self.make_file("old.mkv")
        candidates = self.media()
        with mock.patch.object(cleanup.time, "time", return_value=path.stat().st_mtime):
            self.assertEqual(cleanup.process_files(candidates, False, "test"), 0)
        self.assertTrue(path.exists())

    def test_hardlinks_are_preserved_in_both_modes(self):
        path = self.make_file("old.mkv")
        link = self.root / "other-link.mkv"
        os.link(path, link)
        for dry_run in (True, False):
            self.assertEqual(cleanup.process_files(self.media(), dry_run, "test"), 0)
        self.assertTrue(path.exists())
        self.assertTrue(link.exists())

    def test_target_is_checked_again_after_each_deletion(self):
        oldest = self.make_file("oldest.mkv", age=20)
        newer = self.make_file("newer.mkv")
        with mock.patch.object(cleanup.shutil, "disk_usage", side_effect=[
            SimpleNamespace(free=0), SimpleNamespace(free=1024 ** 3)
        ]) as usage:
            self.assertEqual(cleanup.process_files(self.media(), False, "test", 1), 5)
        self.assertEqual(usage.call_count, 2)
        self.assertFalse(oldest.exists())
        self.assertTrue(newer.exists())

    def test_target_is_checked_for_each_filesystem_not_a_global_stop(self):
        enough_space = self.make_file("first/old.mkv", age=20)
        low_space = self.make_file("second/old.mkv")
        with mock.patch.object(cleanup.shutil, "disk_usage", side_effect=[
            SimpleNamespace(free=1024 ** 3), SimpleNamespace(free=0)
        ]):
            self.assertEqual(cleanup.process_files(self.media(), False, "test", 1), 5)
        self.assertTrue(enough_space.exists())
        self.assertFalse(low_space.exists())

    def test_target_check_failure_preserves_file(self):
        path = self.make_file("old.mkv")
        with mock.patch.object(cleanup.shutil, "disk_usage", side_effect=OSError("disk unavailable")):
            self.assertEqual(cleanup.process_files(self.media(), False, "test", 1), 0)
        self.assertTrue(path.exists())

    def test_dry_run_target_does_not_simulate_logical_space_reclamation(self):
        self.make_file("first.mkv")
        self.make_file("second.mkv")
        with mock.patch.object(cleanup.shutil, "disk_usage", return_value=SimpleNamespace(free=0)):
            self.assertEqual(cleanup.process_files(self.media(), True, "test", 1e-9), 10)
        self.assertEqual(len(self.media()), 2)

    def test_disabled_target_does_not_query_disk_usage(self):
        self.make_file("old.mkv")
        with mock.patch.object(cleanup.shutil, "disk_usage") as usage:
            cleanup.process_files(self.media(), True, "test")
        usage.assert_not_called()

    def test_duplicate_candidates_are_processed_once(self):
        self.make_file("old.mkv")
        candidates = self.media()
        self.assertEqual(cleanup.process_files(candidates * 2, True, "test"), 5)

    def test_unlink_failure_is_logged_and_not_counted(self):
        path = self.make_file("old.mkv")
        with mock.patch.object(Path, "unlink", side_effect=PermissionError("denied")):
            with self.assertLogs(level="ERROR"):
                self.assertEqual(cleanup.process_files(self.media(), False, "test"), 0)
        self.assertTrue(path.exists())

    def test_traversal_errors_are_reported(self):
        def failing_walk(root, onerror):
            onerror(PermissionError("unreadable directory"))
            return iter(())

        with mock.patch.object(cleanup.os, "walk", side_effect=failing_walk):
            with self.assertLogs(level="WARNING") as logs:
                self.assertEqual(self.media(), [])
        self.assertIn("unreadable directory", " ".join(logs.output))

    def test_stat_failures_are_not_reported_as_zero_age(self):
        with self.assertRaises(FileNotFoundError):
            cleanup.get_file_age_days(self.root / "missing.mkv")

    def test_direct_api_rejects_invalid_age_and_target(self):
        for age in (0, -1, float("nan"), float("inf")):
            with self.subTest(age=age), self.assertRaises(ValueError):
                cleanup.find_old_media([str(self.root)], age, False)
        for target in (-1, float("nan"), float("inf")):
            with self.subTest(target=target), self.assertRaises(ValueError):
                cleanup.process_files([], True, "test", target)


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.media_scan = self.enterContext(mock.patch.object(cleanup, "find_old_media", return_value=[]))
        self.qb_scan = self.enterContext(mock.patch.object(cleanup, "find_qb_temp_files", return_value=[]))
        self.process = self.enterContext(mock.patch.object(cleanup, "process_files", return_value=0))
        self.enterContext(mock.patch.object(cleanup.time, "sleep"))
        self.enterContext(mock.patch.object(cleanup, "QB_INCOMPLETE_DIRS", []))

    def assert_invalid(self, args):
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as result:
            cleanup.main(args)
        self.assertEqual(result.exception.code, 2)
        self.media_scan.assert_not_called()
        self.qb_scan.assert_not_called()
        self.process.assert_not_called()

    def test_invalid_arguments_fail_before_scanning(self):
        for args in (
            ["--media-age", "0"], ["--media-age", "-1"],
            ["--qb-age", "0"], ["--qb-age", "-1"], ["--qb-age", "1.5"],
            ["--media-only", "--qb-only"], ["--dry-run", "--execute"],
            ["--target-free-gb", "-1"], ["--target-free-gb", "nan"],
            ["--target-free-gb", "inf"], ["--target-free-gb", "bad"],
        ):
            with self.subTest(args=args):
                self.assert_invalid(args)

    def test_default_is_dry_run_with_qb_disabled(self):
        cleanup.main([])
        self.media_scan.assert_called_once()
        self.qb_scan.assert_not_called()
        self.process.assert_called_once_with([], True, "old media", 0)

    def test_media_execute_requires_acknowledgment(self):
        self.assert_invalid(["--execute", "--media-only"])

    def test_qb_execute_requires_abandoned_confirmation(self):
        self.assert_invalid(["--execute", "--qb-only", "--qb-dir", "/not-scanned"])

    def test_confirmed_media_execute(self):
        cleanup.main(["--execute", "--media-only", "--confirm-filesystem-age", "--use-mtime"])
        self.media_scan.assert_called_once_with(cleanup.MEDIA_DIRS, 365, use_atime=False)
        self.process.assert_called_once_with([], False, "old media", 0)
        self.qb_scan.assert_not_called()

    def test_confirmed_qb_execute_and_repeated_directories(self):
        cleanup.main(["--execute", "--qb-only", "--confirm-qb-abandoned",
                      "--qb-dir", "/not-scanned/one", "--qb-dir", "/not-scanned/two",
                      "--qb-age", "14", "--target-free-gb", "2.5"])
        self.qb_scan.assert_called_once_with(["/not-scanned/one", "/not-scanned/two"], 14)
        self.process.assert_called_once_with([], False, "abandoned qBittorrent partials", 2.5)
        self.media_scan.assert_not_called()

    def test_qb_preview_does_not_require_confirmation(self):
        cleanup.main(["--qb-only", "--qb-dir", "/not-scanned"])
        self.qb_scan.assert_called_once_with(["/not-scanned"], 7)
        self.process.assert_called_once_with([], True, "abandoned qBittorrent partials", 0)

    def test_configured_target_is_passed_to_both_cleanup_phases(self):
        with mock.patch.object(cleanup, "TARGET_FREE_GB", 4):
            cleanup.main(["--qb-dir", "/not-scanned"])
        self.assertEqual(self.process.call_args_list, [
            mock.call([], True, "old media", 4),
            mock.call([], True, "abandoned qBittorrent partials", 4),
        ])

    def test_configured_live_directories_are_not_present_by_default(self):
        self.assertEqual(cleanup.QB_INCOMPLETE_DIRS, [])


if __name__ == "__main__":
    unittest.main()
