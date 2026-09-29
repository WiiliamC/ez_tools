#!/usr/bin/env python3
"""Isolated tests: synthetic data only, no privileged commands or real logs."""

import datetime as dt
import contextlib
import io
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("blackbox", Path(__file__).resolve().parents[1] / "system_blackbox.py")
bb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bb)


class WriterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.day = dt.date(2025, 2, 10)
        self.writer = bb.DailyWriter(self.root, 2, lambda: self.day)

    def tearDown(self):
        self.writer.close()
        self.tmp.cleanup()

    def test_retention_rollover_restart_and_unrelated_files(self):
        for name in ("2025-02-01.jsonl", "2025-02-08.jsonl", "2025-02-09.jsonl", "notes.txt", "2025-99-99.jsonl"):
            (self.root / name).write_text("{}\n")
        (self.root / "2025-01-01.jsonl").symlink_to(self.root / "notes.txt")
        (self.root / "2025-01-02.jsonl").mkdir()
        self.writer.write({"n": 1})
        self.assertFalse((self.root / "2025-02-08.jsonl").exists())
        self.assertFalse((self.root / "2025-02-01.jsonl").exists())
        self.assertTrue((self.root / "2025-02-09.jsonl").exists())
        self.assertTrue((self.root / "2025-01-01.jsonl").is_symlink())
        self.assertTrue((self.root / "2025-01-02.jsonl").is_dir())
        self.assertEqual((self.root / "notes.txt").read_text(), "{}\n")
        self.day += dt.timedelta(days=1)
        self.writer.write({"n": 2})
        self.assertFalse((self.root / "2025-02-09.jsonl").exists())
        self.writer.close()
        self.writer = bb.DailyWriter(self.root, 2, lambda: self.day)
        self.writer.write({"n": 3})
        self.assertEqual(len((self.root / "2025-02-11.jsonl").read_text().splitlines()), 2)
        self.assertEqual((self.root / "2025-02-11.jsonl").stat().st_mode & 0o777, 0o600)

    def test_tail_recovery_and_lock(self):
        target = self.root / "2025-02-10.jsonl"
        target.write_bytes(b'{"valid":true}\n{"broken":')
        with self.assertRaises(BlockingIOError):
            bb.DailyWriter(self.root, 2)
        self.writer.write({"n": 2})
        rows = [json.loads(line) for line in target.read_text().splitlines()]
        self.assertEqual(rows[0], {"valid": True})
        self.assertEqual(rows[1]["recovery"]["truncated_tail_bytes"], 10)

    def test_rollback_keeps_future_and_custom_retention(self):
        self.writer.retention_days = 1
        self.writer.write({"n": 1})
        self.day -= dt.timedelta(days=1)
        self.writer.write({"n": 2})
        self.assertTrue((self.root / "2025-02-10.jsonl").exists())
        self.day += dt.timedelta(days=5)
        self.writer.write({"n": 3})
        self.assertFalse((self.root / "2025-02-10.jsonl").exists())

    def test_io_failure_propagates(self):
        self.writer.write({"n": 1})
        with patch.object(bb.os, "write", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.writer.write({"n": 2})
        with patch.object(bb.os, "fdatasync", side_effect=OSError("sync failure")):
            with self.assertRaises(OSError):
                self.writer.write({"n": 3})

    def test_log_symlink_is_rejected(self):
        target = self.root / "unrelated"
        target.write_text("safe")
        (self.root / "2025-02-10.jsonl").symlink_to(target)
        with self.assertRaises(OSError):
            self.writer.write({"n": 1})
        self.assertEqual(target.read_text(), "safe")

    def test_parent_traversal_cannot_select_shared_directory(self):
        with self.assertRaisesRegex(ValueError, "dedicated"):
            bb.DailyWriter(self.root / "..", 2)

    def test_hardlink_target_is_rejected(self):
        target = self.root / "unrelated"
        target.write_text("safe")
        os.link(target, self.root / "2025-02-10.jsonl")
        with self.assertRaisesRegex(ValueError, "hard links"):
            self.writer.write({"n": 1})
        self.assertEqual(target.read_text(), "safe")


class MetricsTests(unittest.TestCase):
    def test_process_pid_reuse_has_no_false_rate(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            process = root / "42"
            process.mkdir()
            def write_stat(start, ticks):
                fields = ["0"] * 22
                fields[0], fields[11], fields[12], fields[19], fields[21] = "S", str(ticks), "0", str(start), "10"
                (process / "stat").write_text("42 (example worker) " + " ".join(fields))
                (process / "io").write_text("read_bytes: 100\nwrite_bytes: 100\n")
            collector = bb.ProcessMetrics(root)
            write_stat(1, 10)
            collector()
            write_stat(2, 10000)
            self.assertIsNone(collector()["top"][0]["cpu_percent"])

    def test_energy_wrap_and_unreadable(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            zone = root / "class/powercap/example:0"
            zone.mkdir(parents=True)
            (zone / "name").write_text("package-0")
            (zone / "energy_uj").write_text("9000000")
            (zone / "max_energy_range_uj").write_text("10000000")
            collector = bb.HardwareMetrics(root)
            with patch.object(bb.time, "monotonic", return_value=1):
                self.assertIsNone(collector()["rapl"]["example:0"]["watts"])
            (zone / "energy_uj").write_text("1000000")
            with patch.object(bb.time, "monotonic", return_value=2):
                self.assertEqual(collector()["rapl"]["example:0"]["watts"], 2)
            (zone / "energy_uj").write_text("unavailable")
            result = collector()
            self.assertIsNone(result["rapl"]["example:0"]["watts"])
            self.assertIn("example:0", result["unreadable"])

    def test_cpu_rates_use_deltas_not_lifetime_average(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "net").mkdir()
            (root / "net/dev").write_text("header\nheader\neth0: 100 0 0 0 0 0 0 0 200 0 0 0 0 0 0 0\n")
            (root / "stat").write_text("cpu 10 0 10 80 0 0 0 0 0 0\n")
            (root / "meminfo").write_text("MemAvailable: 100 kB\n")
            (root / "vmstat").write_text("pswpin 10\npswpout 20\n")
            (root / "diskstats").write_text("")
            (root / "loadavg").write_text("1 2 3 1/10 10\n")
            collector = bb.ProcMetrics(root, root / "sys")
            with patch.object(bb.time, "monotonic", return_value=1):
                self.assertIsNone(collector()["cpu_percent"]["cpu"])
            (root / "stat").write_text("cpu 30 0 10 100 0 0 0 0 0 0\n")
            (root / "vmstat").write_text("pswpin 14\npswpout 26\n")
            with patch.object(bb.time, "monotonic", return_value=3):
                result = collector()
            self.assertEqual(result["cpu_percent"]["cpu"], 50)
            self.assertEqual(result["swap_pages_per_second"]["pswpin"], 2)
            self.assertEqual(result["memory"]["MemAvailable_bytes"], 102400)

    def test_gpu_optional_field_and_unsupported_values(self):
        with patch.object(bb, "command", side_effect=[RuntimeError(), "0, 0, 44, 32000, 40, [N/A], 500, 100, 100\n"]):
            result = bb.gpu_metrics()["gpus"][0]
            self.assertIsNone(result["power.draw"])
            self.assertIsNone(result["clocks_event_reasons.active"])

    def test_stale_source_is_explicit(self):
        source = bb.Source.__new__(bb.Source)
        source.period = 1
        source.latest = {"status": "ok", "data": {"value": 1}, "collected_monotonic": 10}
        from unittest.mock import Mock
        source.process = Mock()
        source.process.is_alive.return_value = True
        self.assertEqual(source.snapshot(15)["status"], "stale")
        self.assertEqual(source.snapshot(15)["age_seconds"], 5)
        source.latest = None
        source.started = 10
        self.assertEqual(source.snapshot(15)["status"], "timeout")


class IntegrationTests(unittest.TestCase):
    def test_source_close_kills_and_reaps_active_collector_command(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            pid_file = root / "helper.pid"
            executable = root / "nvidia-smi"
            executable.write_text(
                "#!" + sys.executable + "\n"
                "import os, signal, time\n"
                "from pathlib import Path\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "Path(os.environ['HELPER_PID_FILE']).write_text(str(os.getpid()))\n"
                "time.sleep(30)\n"
            )
            executable.chmod(0o700)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"],
                       HELPER_PID_FILE=str(pid_file))
            runner = """
import os, time
from pathlib import Path
from system_blackbox import Source
source = Source('gpu', 1, '.')
try:
    source.poll(time.monotonic())
    pid_file = Path(os.environ['HELPER_PID_FILE'])
    deadline = time.monotonic() + 5
    while not pid_file.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    pid = int(pid_file.read_text())
finally:
    source.close()
assert not source.process.is_alive(), 'worker survived close()'
assert not Path('/proc', str(pid)).exists(), 'helper survived or was not reaped'
"""
            try:
                result = subprocess.run(
                    [sys.executable, "-c", runner], env=env,
                    cwd=Path(__file__).resolve().parents[1],
                    capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
            finally:
                if pid_file.exists():
                    try:
                        os.kill(int(pid_file.read_text()), signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_sigterm_releases_lock_and_leaves_complete_records(self):
        script = Path(__file__).resolve().parents[1] / "system_blackbox.py"
        with tempfile.TemporaryDirectory() as directory:
            log_dir = Path(directory) / "logs"
            proc = subprocess.Popen([sys.executable, str(script), "run", "--log-dir", str(log_dir), "--interval", "0.1"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if len(list(bb.iter_records(log_dir))) >= 3:
                        break
                    time.sleep(0.05)
                self.assertGreaterEqual(len(list(bb.iter_records(log_dir))), 3)
                proc.terminate()
                _, error = proc.communicate(timeout=5)
                self.assertEqual(proc.returncode, 0, error)
                writer = bb.DailyWriter(log_dir, 2)
                writer.close()
                for path in log_dir.glob('*.jsonl'):
                    for line in path.read_text().splitlines():
                        json.loads(line)
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.communicate(timeout=5)

    def test_blocked_gpu_does_not_stop_logging_and_restart_appends(self):
        script = Path(__file__).resolve().parents[1] / "system_blackbox.py"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            executable = root / "nvidia-smi"
            executable.write_text("#!" + sys.executable + "\nimport time\ntime.sleep(30)\n")
            executable.chmod(0o700)
            env = dict(os.environ, PATH=str(root) + os.pathsep + os.environ["PATH"])
            log_dir = root / "logs"
            cmd = [sys.executable, str(script), "run", "--log-dir", str(log_dir), "--interval", "0.2", "--duration", "4"]
            begin = time.monotonic()
            subprocess.run(cmd, env=env, check=True, capture_output=True, timeout=10)
            self.assertLess(time.monotonic() - begin, 9)
            rows = list(bb.iter_records(log_dir))
            self.assertGreater(len(rows), 10)
            self.assertTrue(any(row["sources"]["system"]["status"] == "ok" for row in rows))
            self.assertTrue(any(row["sources"]["gpu"]["status"] in ("timeout", "error") for row in rows))
            old_count = len(rows)
            cmd[-1] = "0.5"
            subprocess.run(cmd, env=env, check=True, capture_output=True, timeout=10)
            self.assertGreater(len(list(bb.iter_records(log_dir))), old_count)
            result = subprocess.run([sys.executable, str(script), "report", "--log-dir", str(log_dir), "--boot-id", "current", "--no-journal"], capture_output=True, text=True, check=True)
            summary = json.loads(result.stdout)
            self.assertGreater(summary["samples"], old_count)
            self.assertIn("cpu_percent", summary["peaks"])
            result = subprocess.run([sys.executable, str(script), "status", "--log-dir", str(log_dir)], capture_output=True, text=True, check=True)
            self.assertGreater(json.loads(result.stdout)["total_bytes"], 0)

    def test_invalid_settings_fail_before_creating_logs(self):
        script = Path(__file__).resolve().parents[1] / "system_blackbox.py"
        for option, value in (("--interval", "nan"), ("--interval", "0"), ("--retention-days", "0"), ("--retention-days", "1.5")):
            result = subprocess.run([sys.executable, str(script), "run", option, value], capture_output=True)
            self.assertNotEqual(result.returncode, 0)


class ReportTests(unittest.TestCase):
    def test_previous_boot_time_window_and_stale_peaks(self):
        with tempfile.TemporaryDirectory() as directory:
            rows = []
            for boot, mono, temp, state in (("previous", 1, 999, "ok"), ("previous", 700, 45, "ok"), ("previous", 701, 999, "stale"), ("current", 5, 30, "ok")):
                rows.append({"version": 1, "boot_id": boot, "monotonic_seconds": mono,
                             "timestamp": "2025-02-10T12:00:00+00:00",
                             "sources": {"hardware": {"status": state, "data": {"temperature_c": {"example": temp}}}}})
            Path(directory, "2025-02-10.jsonl").write_text("\n".join(json.dumps(row) for row in rows) + '\n{"incomplete":')
            args = SimpleNamespace(log_dir=directory, boot_id=None, minutes=10, no_journal=True)
            output = io.StringIO()
            with patch.object(bb, "read", return_value="current"), contextlib.redirect_stdout(output):
                bb.report(args)
            result = json.loads(output.getvalue())
            self.assertEqual(result["boot_id"], "previous")
            self.assertEqual(result["samples"], 2)
            self.assertEqual(result["peaks"]["temperature_c:example"], 45)
            args.no_journal = False
            output = io.StringIO()
            with patch.object(bb, "read", return_value="current"), patch.object(bb.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, "-- No entries --\n", "")), contextlib.redirect_stdout(output):
                bb.report(args)
            self.assertIn("No matching accessible entries", output.getvalue())
            self.assertNotIn("query failed", output.getvalue())

    def test_no_previous_boot_is_not_silently_current(self):
        with tempfile.TemporaryDirectory() as directory:
            args = SimpleNamespace(log_dir=directory, boot_id=None, minutes=10, no_journal=True)
            with self.assertRaisesRegex(ValueError, "no matching boot"):
                bb.report(args)


if __name__ == "__main__":
    unittest.main()
