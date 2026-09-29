#!/usr/bin/env python3
"""Bounded, crash-tolerant Linux telemetry; Python standard library only."""

import argparse
import datetime as dt
import fcntl
import json
import math
import multiprocessing as mp
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import statistics
import subprocess
import sys
import time

DEFAULT_DIR = "/var/log/system-blackbox"
DATE_FILE = re.compile(r"\d{4}-\d{2}-\d{2}\.jsonl\Z")


def read(path):
    return Path(path).read_text().strip()


def number(path, scale=1):
    try:
        return float(read(path)) / scale
    except (OSError, ValueError):
        return None


def command(args, timeout=3):
    result = subprocess.run(args, capture_output=True, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError("command failed (exit %d)" % result.returncode)
    return result.stdout


class ProcMetrics:
    def __init__(self, root="/proc", sysroot="/sys"):
        self.root, self.sysroot = Path(root), Path(sysroot)
        self.previous = None

    def __call__(self):
        now = time.monotonic()
        cpu = {}
        for line in read(self.root / "stat").splitlines():
            fields = line.split()
            if re.fullmatch(r"cpu\d*", fields[0]):
                values = list(map(int, fields[1:9]))  # guest already included in user/nice
                cpu[fields[0]] = (sum(values), values[3] + values[4])
        memory = {}
        for line in read(self.root / "meminfo").splitlines():
            fields = line.split()
            if fields[0][:-1] in {"MemTotal", "MemAvailable", "SwapTotal", "SwapFree", "Dirty", "Writeback"}:
                memory[fields[0][:-1] + "_bytes"] = int(fields[1]) * 1024
        vm = dict(line.split() for line in read(self.root / "vmstat").splitlines())
        swap = {key: int(vm[key]) for key in ("pswpin", "pswpout")}
        disks = {}
        for line in read(self.root / "diskstats").splitlines():
            f = line.split()
            if not (self.sysroot / "block" / f[2] / "device").exists():
                continue
            disks[f[2]] = dict(zip(
                ("reads", "read_sectors", "read_ms", "writes", "write_sectors", "write_ms", "in_flight", "io_ms", "weighted_ms"),
                (int(f[i]) for i in (3, 5, 6, 7, 9, 10, 11, 12, 13))))
        network = {}
        for line in read(self.root / "net/dev").splitlines()[2:]:
            name, values = line.split(":", 1)
            v = list(map(int, values.split()))
            network[name.strip()] = {"rx_bytes": v[0], "tx_bytes": v[8], "rx_errors": v[2], "tx_errors": v[10]}
        pressure = {}
        for kind in ("cpu", "memory", "io"):
            try:
                pressure[kind] = {f[0]: {k: float(v) for k, v in (item.split("=") for item in f[1:])}
                                  for f in (line.split() for line in read(self.root / "pressure" / kind).splitlines())}
            except OSError:
                pressure[kind] = None
        result = {"cpu_percent": {key: None for key in cpu}, "load": list(map(float, read(self.root / "loadavg").split()[:3])),
                  "memory": memory, "swap_pages_per_second": None, "pressure": pressure,
                  "disks": {}, "network": {}, "cpu_mhz": {}}
        for p in (self.sysroot / "devices/system/cpu").glob("cpu[0-9]*/cpufreq/scaling_cur_freq"):
            result["cpu_mhz"][p.parent.parent.name] = number(p, 1000)
        old = self.previous
        self.previous = (now, cpu, swap, disks, network)
        elapsed = now - old[0] if old else 0
        def rate(current, previous, key):
            delta = current[key] - previous[key]
            return delta / elapsed if delta >= 0 else None
        if old and elapsed > 0:
            for name, (total, idle) in cpu.items():
                if name in old[1]:
                    td, idled = total - old[1][name][0], idle - old[1][name][1]
                    if td > 0 and 0 <= idled <= td:
                        result["cpu_percent"][name] = round(100 * (td - idled) / td, 2)
            result["swap_pages_per_second"] = {k: rate(swap, old[2], k) for k in swap}
        for name, current in disks.items():
            entry = {"in_flight": current["in_flight"], "read_bytes_s": None, "write_bytes_s": None,
                     "read_iops": None, "write_iops": None, "await_ms": None, "queue_depth": None, "busy_percent": None}
            if old and elapsed > 0 and name in old[3]:
                previous = old[3][name]
                if all(current[k] >= previous[k] for k in current if k != "in_flight"):
                    count = current["reads"] + current["writes"] - previous["reads"] - previous["writes"]
                    entry.update(read_bytes_s=rate(current, previous, "read_sectors") * 512,
                                 write_bytes_s=rate(current, previous, "write_sectors") * 512,
                                 read_iops=rate(current, previous, "reads"), write_iops=rate(current, previous, "writes"),
                                 await_ms=(current["read_ms"] + current["write_ms"] - previous["read_ms"] - previous["write_ms"]) / count if count else 0,
                                 queue_depth=rate(current, previous, "weighted_ms") / 1000,
                                 busy_percent=rate(current, previous, "io_ms") / 10)
            result["disks"][name] = entry
        for name, current in network.items():
            result["network"][name] = {"rx_bytes_s": None, "tx_bytes_s": None,
                                       "rx_errors": current["rx_errors"], "tx_errors": current["tx_errors"]}
            if old and elapsed > 0 and name in old[4]:
                for key in ("rx_bytes", "tx_bytes"):
                    result["network"][name][key + "_s"] = rate(current, old[4][name], key)
        return result


class HardwareMetrics:
    def __init__(self, root="/sys"):
        self.root, self.previous = Path(root), {}

    def __call__(self):
        temperatures, fans, power, errors = {}, {}, {}, []
        for hw in (self.root / "class/hwmon").glob("hwmon*"):
            try:
                name = read(hw / "name")
            except OSError:
                name = hw.name
            for kind, target, scale in (("temp", temperatures, 1000), ("fan", fans, 1), ("power", power, 1000000)):
                for p in hw.glob(kind + "*_input"):
                    label_path = p.with_name(p.name.replace("_input", "_label"))
                    try:
                        label = read(label_path)
                    except OSError:
                        label = p.stem
                    key = "%s:%s:%s" % (hw.name, name, label)
                    target[key] = number(p, scale)
                    if target[key] is None:
                        errors.append(key)
        rapl = {}
        # class entries are symlinks; glob each immediate zone exactly once.
        for zone in (self.root / "class/powercap").glob("*"):
            if not (zone / "energy_uj").exists():
                continue
            energy, limit = number(zone / "energy_uj"), number(zone / "max_energy_range_uj")
            now = time.monotonic()
            watts = None
            previous = self.previous.get(zone.name)
            if energy is not None:
                if previous and now > previous[0]:
                    delta = energy - previous[1]
                    if delta < 0 and limit is not None:
                        delta += limit
                    if delta >= 0:
                        watts = delta / 1e6 / (now - previous[0])
                self.previous[zone.name] = (now, energy)
            else:
                self.previous.pop(zone.name, None)
                errors.append(zone.name)
            try:
                label = read(zone / "name")
            except OSError:
                label = zone.name
            rapl[zone.name] = {"domain": label, "watts": watts}
        return {"temperature_c": temperatures, "fan_rpm": fans, "power_w": power, "rapl": rapl,
                "unreadable": errors}


def gpu_metrics():
    fields = ["index", "utilization.gpu", "memory.used", "memory.total", "temperature.gpu", "power.draw",
              "power.limit", "clocks.current.graphics", "clocks.current.memory", "clocks_event_reasons.active"]
    optional_error = False
    try:
        output = command(["nvidia-smi", "--query-gpu=" + ",".join(fields), "--format=csv,noheader,nounits"])
    except RuntimeError:
        fields.pop()
        optional_error = True
        output = command(["nvidia-smi", "--query-gpu=" + ",".join(fields), "--format=csv,noheader,nounits"])
    rows = []
    for line in output.splitlines():
        row = {}
        for key, value in zip(fields, line.split(",")):
            value = value.strip()
            try:
                row[key] = int(value, 16) if value.startswith("0x") else float(value)
                if not math.isfinite(row[key]):
                    row[key] = None
            except ValueError:
                row[key] = None
        if optional_error:
            row["clocks_event_reasons.active"] = None
        rows.append(row)
    return {"gpus": rows}


class ProcessMetrics:
    def __init__(self, root="/proc"):
        self.root, self.previous = Path(root), None
        self.hz, self.page = os.sysconf("SC_CLK_TCK"), os.sysconf("SC_PAGE_SIZE")

    def __call__(self):
        now, current, rows = time.monotonic(), {}, []
        denied = 0
        for path in self.root.glob("[0-9]*"):
            try:
                raw = read(path / "stat")
                end = raw.rfind(")")
                fields = raw[end + 2:].split()
                key = (int(path.name), int(fields[19]))  # PID + starttime, safe across reuse
                ticks, rss = int(fields[11]) + int(fields[12]), int(fields[21]) * self.page
                try:
                    io = dict(line.split(": ") for line in read(path / "io").splitlines())
                    size = int(io["read_bytes"]) + int(io["write_bytes"])
                except OSError:
                    size = None
                    denied += 1
                current[key] = (ticks, size)
                cpu, io_rate = None, None
                if self.previous and key in self.previous[1]:
                    elapsed = now - self.previous[0]
                    before = self.previous[1][key]
                    if elapsed > 0:
                        cpu = max(0, ticks - before[0]) / self.hz / elapsed * 100
                        if size is not None and before[1] is not None:
                            io_rate = max(0, size - before[1]) / elapsed
                rows.append({"pid": key[0], "name": raw[raw.find("(") + 1:end], "cpu_percent": cpu,
                             "rss_bytes": rss, "io_bytes_s": io_rate})
            except (OSError, ValueError, IndexError):
                continue  # process exited while reading
        self.previous = (now, current)
        chosen = {}
        for metric in ("cpu_percent", "rss_bytes", "io_bytes_s"):
            for row in sorted(rows, key=lambda x: x[metric] if x[metric] is not None else -1, reverse=True)[:10]:
                chosen[row["pid"]] = row
        return {"top": list(chosen.values()), "process_count": len(rows), "io_unreadable_count": denied}


def health_metrics(log_dir):
    filesystems = []
    # Keep mount paths out of telemetry. Deduplicate aliases using filesystem device ID.
    seen = set()
    for target in ("/", log_dir):
        st = os.stat(target)
        if st.st_dev not in seen:
            usage = shutil.disk_usage(target)
            filesystems.append({"role": "root" if target == "/" else "log", "total_bytes": usage.total, "free_bytes": usage.free})
            seen.add(st.st_dev)
    disks = {}
    if shutil.which("smartctl"):
        for path in Path("/sys/block").glob("*"):
            if not re.fullmatch(r"(?:nvme\d+n\d+|sd[a-z]+)", path.name):
                continue
            try:
                # smartctl exit bits can indicate device health errors; retain valid JSON.
                result = subprocess.run(["smartctl", "-j", "-a", "/dev/" + path.name], capture_output=True, text=True, timeout=5)
                data = json.loads(result.stdout)
                nvme = data.get("nvme_smart_health_information_log", {})
                disks[path.name] = {"exit_status": result.returncode, "passed": data.get("smart_status", {}).get("passed"),
                                    "temperature_c": data.get("temperature", {}).get("current"),
                                    "nvme": {key: nvme.get(key) for key in ("critical_warning", "available_spare", "percentage_used", "media_errors", "num_err_log_entries", "unsafe_shutdowns")}}
            except (OSError, ValueError, subprocess.TimeoutExpired):
                disks[path.name] = {"error": "unavailable"}
    return {"filesystems": filesystems, "smart_available": bool(shutil.which("smartctl")), "disks": disks}


def worker_main(conn, kind, log_dir):
    def stop(signum, frame):
        # Unwind subprocess.run(), which kills and reaps its active child.
        # SystemExit also bypasses the collector's Exception handler.
        raise SystemExit(0)

    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, stop)
    # Workers must not inherit the writer's lock or open log. Created before writer.
    collector = {"system": ProcMetrics, "hardware": HardwareMetrics, "processes": ProcessMetrics}.get(kind)
    collect = collector() if collector else (gpu_metrics if kind == "gpu" else lambda: health_metrics(log_dir))
    try:
        while conn.recv():
            try:
                data = collect()
                conn.send({"status": "ok", "data": data, "collected_monotonic": time.monotonic()})
            except Exception as exc:
                # Avoid copying command output or machine paths into diagnostic errors.
                conn.send({"status": "error", "data": None, "error": type(exc).__name__, "collected_monotonic": time.monotonic()})
    except (EOFError, BrokenPipeError):
        pass
    finally:
        conn.close()


class Source:
    def __init__(self, kind, period, log_dir):
        ctx = mp.get_context("spawn")
        self.conn, child = ctx.Pipe()
        self.process = ctx.Process(target=worker_main, args=(child, kind, log_dir), daemon=True)
        self.process.start()
        child.close()
        self.period, self.next_due, self.started = period, 0, None
        self.latest, self.fresh = None, False

    def poll(self, now):
        try:
            if self.conn.poll():
                self.latest = self.conn.recv()
                self.started, self.fresh = None, True
            if self.started is None and now >= self.next_due and self.process.is_alive():
                self.conn.send(True)
                self.started, self.next_due = now, now + self.period
        except (EOFError, BrokenPipeError, OSError):
            pass

    def snapshot(self, now):
        if not self.process.is_alive():
            return {"status": "worker_exited", "data": None}
        if self.latest is None:
            return {"status": "pending" if self.started is None or now - self.started < 3 else "timeout", "data": None}
        age = max(0, now - self.latest["collected_monotonic"])
        result = dict(self.latest, age_seconds=round(age, 3))
        if age > max(3, self.period * 2):
            result["status"] = "stale"
        return result

    def close(self):
        self.conn.close()
        self.process.terminate()
        self.process.join(timeout=0.3)
        if self.process.is_alive():
            self.process.kill()
            self.process.join(timeout=0.3)


class DailyWriter:
    def __init__(self, directory, retention_days, today=None):
        supplied = Path(directory).absolute()
        if any(p.is_symlink() for p in [supplied, *supplied.parents]):
            raise ValueError("log directory must not contain symlink components")
        self.directory = Path(os.path.abspath(supplied))
        if self.directory in (Path('/'), Path('/var'), Path('/var/log'), Path('/tmp'), Path('/home')):
            raise ValueError("use a dedicated log subdirectory")
        if any(p.is_symlink() for p in [self.directory, *self.directory.parents]):
            raise ValueError("log directory must not contain symlink components")
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(self.directory, 0o700)
        self.retention_days = retention_days
        self.lock = os.open(self.directory / ".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            if not stat.S_ISREG(os.fstat(self.lock).st_mode):
                raise ValueError("lock must be a regular file")
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BaseException:
            os.close(self.lock)
            raise
        self.fd, self.day, self.last_cleanup = None, None, 0
        self.today = today or (lambda: dt.datetime.now().astimezone().date())

    def sync_directory(self):
        fd = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def cleanup(self, day):
        cutoff = day - dt.timedelta(days=self.retention_days - 1)
        changed = False
        for path in self.directory.iterdir():
            if path.is_symlink() or not path.is_file() or not DATE_FILE.fullmatch(path.name):
                continue
            try:
                date = dt.date.fromisoformat(path.stem)
            except ValueError:
                continue
            # Preserve future files after a wall-clock rollback.
            if date < cutoff:
                path.unlink()
                changed = True
        if changed:
            self.sync_directory()
        self.last_cleanup = time.monotonic()

    def rotate(self, day):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        self.fd = os.open(self.directory / (day.isoformat() + ".jsonl"), os.O_CREAT | os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        file_stat = os.fstat(self.fd)
        if not stat.S_ISREG(file_stat.st_mode) or file_stat.st_nlink != 1:
            raise ValueError("log target must be a regular file without hard links")
        os.fchmod(self.fd, 0o600)
        size = os.fstat(self.fd).st_size
        recovered = 0
        # Only the last, incomplete line can be damaged by an interrupted append.
        if size and os.pread(self.fd, 1, size - 1) != b"\n":
            position, cut = size, 0
            while position:
                start = max(0, position - 8192)
                chunk = os.pread(self.fd, position - start, start)
                index = chunk.rfind(b"\n")
                if index >= 0:
                    cut = start + index + 1
                    break
                position = start
            recovered = size - cut
            os.ftruncate(self.fd, cut)
        self.day = day
        os.fdatasync(self.fd)
        self.sync_directory()
        self.cleanup(day)
        return recovered

    def write(self, record):
        day = self.today()
        if day != self.day:
            recovered = self.rotate(day)
            if recovered:
                record["recovery"] = {"truncated_tail_bytes": recovered}
        elif time.monotonic() - self.last_cleanup >= 3600:
            self.cleanup(day)
        payload = (json.dumps(record, ensure_ascii=True, separators=(",", ":"), allow_nan=False) + "\n").encode()
        while payload:
            count = os.write(self.fd, payload)
            if count <= 0:
                raise OSError("short write")
            payload = payload[count:]
        os.fdatasync(self.fd)

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        os.close(self.lock)


def run(args):
    stopping = False
    def stop(*_):
        nonlocal stopping
        stopping = True
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    os.umask(0o077)
    writer = DailyWriter(args.log_dir, args.retention_days)
    sources = {}
    try:
        for kind, period in (("system", args.interval), ("hardware", args.interval), ("gpu", args.interval), ("processes", 10), ("health", 60)):
            sources[kind] = Source(kind, period, args.log_dir)
        boot_id = read("/proc/sys/kernel/random/boot_id")
        started = deadline = time.monotonic()
        previous_write_ms = None
        while not stopping and (args.duration is None or time.monotonic() - started < args.duration):
            now = time.monotonic()
            for source in sources.values():
                source.poll(now)
            if now >= deadline:
                record = {"version": 1, "timestamp": dt.datetime.now().astimezone().isoformat(timespec="milliseconds"),
                          "boot_id": boot_id, "monotonic_seconds": now, "uptime_seconds": float(read("/proc/uptime").split()[0]),
                          "collector": {"previous_write_sync_ms": previous_write_ms, "schedule_lag_seconds": max(0, now - deadline)}, "sources": {}}
                for kind, source in sources.items():
                    if kind in ("system", "hardware", "gpu") or source.fresh:
                        record["sources"][kind] = source.snapshot(now)
                    else:
                        record["sources"][kind] = {k: v for k, v in source.snapshot(now).items() if k != "data"}
                    source.fresh = False
                write_started = time.monotonic()
                writer.write(record)
                previous_write_ms = round((time.monotonic() - write_started) * 1000, 3)
                deadline += args.interval
                if deadline <= time.monotonic():
                    deadline = time.monotonic() + args.interval
            time.sleep(min(0.05, max(0, deadline - time.monotonic())))
    finally:
        for source in sources.values():
            source.close()
        writer.close()


def iter_records(directory):
    for path in sorted(Path(directory).glob("????-??-??.jsonl")):
        if path.is_symlink() or not path.is_file() or not DATE_FILE.fullmatch(path.name):
            continue
        with path.open() as stream:
            for line in stream:
                try:
                    record = json.loads(line)
                    if record.get("version") == 1 and "boot_id" in record:
                        yield record
                except (ValueError, AttributeError):
                    continue


def status(args):
    sizes, last = [], None
    for path in sorted(Path(args.log_dir).glob("????-??-??.jsonl")):
        if path.is_file() and not path.is_symlink() and DATE_FILE.fullmatch(path.name):
            sizes.append({"date": path.stem, "bytes": path.stat().st_size})
            # Status should not scan gigabytes of historical samples.
            with path.open("rb") as stream:
                stream.seek(max(0, path.stat().st_size - 1024 * 1024))
                tail = stream.read().splitlines()
            for line in reversed(tail):
                try:
                    candidate = json.loads(line)
                    if candidate.get("version") == 1 and "sources" in candidate:
                        if last is None or candidate["timestamp"] > last["timestamp"]:
                            last = candidate
                        break
                except (ValueError, AttributeError):
                    continue
    print(json.dumps({"files": sizes, "total_bytes": sum(x["bytes"] for x in sizes),
                      "last_timestamp": last["timestamp"] if last else None,
                      "sources": {k: {f: v[f] for f in ("status", "age_seconds", "error") if f in v} for k, v in last["sources"].items()} if last else {}}, indent=2))


def report(args):
    current = read("/proc/sys/kernel/random/boot_id")
    boots = {}
    for record in iter_records(args.log_dir):
        boot = record["boot_id"]
        entry = boots.setdefault(boot, {"timestamp": record["timestamp"], "end": 0})
        entry["timestamp"] = max(entry["timestamp"], record["timestamp"])
        entry["end"] = max(entry["end"], record["monotonic_seconds"])
    selected = args.boot_id
    if selected == "current":
        selected = current
    if not selected:
        candidates = [b for b in boots if b != current]
        selected = max(candidates, key=lambda b: boots[b]["timestamp"]) if candidates else None
    if selected not in boots:
        raise ValueError("no matching boot in retained logs; use --boot-id current for this boot")
    end = boots[selected]["end"]
    count, times, peaks, processes, states = 0, [], {}, {}, {}
    first_wall = last_wall = None
    def peak(key, value):
        if isinstance(value, (int, float)):
            peaks[key] = max(peaks.get(key, value), value)
    for row in iter_records(args.log_dir):
        if row["boot_id"] != selected or row["monotonic_seconds"] < end - args.minutes * 60:
            continue
        count += 1
        times.append(row["monotonic_seconds"])
        first_wall = min(first_wall or row["timestamp"], row["timestamp"])
        last_wall = max(last_wall or row["timestamp"], row["timestamp"])
        for kind, source in row["sources"].items():
            state = kind + ":" + source["status"]
            states[state] = states.get(state, 0) + 1
            data = source.get("data") or {}
            if source["status"] != "ok":
                continue
            if kind == "hardware":
                for metric in ("temperature_c", "power_w", "fan_rpm"):
                    for name, value in data.get(metric, {}).items():
                        peak(metric + ":" + name, value)
                for name, value in data.get("rapl", {}).items():
                    peak("rapl_w:" + name, value["watts"])
            elif kind == "system":
                peak("cpu_percent", data.get("cpu_percent", {}).get("cpu"))
                if data.get("load"):
                    peak("load1", data["load"][0])
                memory = data.get("memory", {})
                if "MemTotal_bytes" in memory and "MemAvailable_bytes" in memory:
                    peak("memory_used_bytes", memory["MemTotal_bytes"] - memory["MemAvailable_bytes"])
                for resource, modes in data.get("pressure", {}).items():
                    for mode, values in (modes or {}).items():
                        peak("psi:%s:%s:avg10" % (resource, mode), values.get("avg10"))
                for disk, values in data.get("disks", {}).items():
                    for metric in ("await_ms", "queue_depth", "busy_percent"):
                        peak("disk:%s:%s" % (disk, metric), values.get(metric))
            elif kind == "gpu":
                for gpu in data.get("gpus", []):
                    for metric in ("temperature.gpu", "power.draw", "utilization.gpu", "memory.used"):
                        peak("gpu%s:%s" % (gpu.get("index"), metric), gpu.get(metric))
            elif kind == "processes":
                for process in data.get("top", []):
                    key = (process["pid"], process["name"])
                    entry = processes.setdefault(key, dict(process))
                    for metric in ("cpu_percent", "rss_bytes", "io_bytes_s"):
                        if process[metric] is not None:
                            entry[metric] = max(entry[metric] or 0, process[metric])
    times.sort()
    intervals = [b - a for a, b in zip(times, times[1:]) if b > a]
    typical = statistics.median(intervals) if intervals else None
    result = {"boot_id": selected, "from": first_wall, "to": last_wall, "samples": count,
              "median_interval_seconds": typical, "max_gap_seconds": max(intervals, default=0),
              "gaps_over_twice_median": sum(x > typical * 2 for x in intervals) if typical else 0,
              "source_status_counts": states, "peaks": peaks,
              "top_processes": {metric: sorted(processes.values(), key=lambda p: p[metric] or 0, reverse=True)[:10]
                                for metric in ("cpu_percent", "rss_bytes", "io_bytes_s")},
              "interpretation": "Observations only. An abrupt log end does not establish a power-supply fault."}
    print(json.dumps(result, indent=2, ensure_ascii=True))
    if args.no_journal:
        return
    print("\nJournal: kernel warnings/errors and shutdown events (last 200 matches):")
    try:
        since = str(int(dt.datetime.fromisoformat(first_wall).timestamp()))
        # Include shutdown messages just after the collector's final sample.
        until = str(int(dt.datetime.fromisoformat(last_wall).timestamp()) + 60)
        result = subprocess.run(["journalctl", "--boot=" + selected, "--since=@" + since, "--until=@" + until,
                          "--no-pager", "-o", "short-iso", "--grep=oom|out of memory|xid|mce|edac|aer|nvme|thermal|temperature|watchdog|lockup|shutdown|shutting down|power.?off|reboot", "--case-sensitive=no", "-n", "200"], timeout=10, capture_output=True, text=True)
        if result.returncode == 0:
            print(result.stdout or "No matching accessible entries; this does not prove no events occurred.")
        elif result.returncode == 1 and not result.stderr.strip():
            print("No matching accessible entries; this does not prove no events occurred.")
        else:
            print("Journal unavailable or query failed; check historical persistence/access separately.")
    except (OSError, RuntimeError, subprocess.TimeoutExpired):
        print("Journal unavailable or query failed; historical persistence/access must be checked separately.")


def positive_int(value):
    result = int(value)
    if result <= 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return result


def positive_float(value):
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise argparse.ArgumentTypeError("must be finite and positive")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("run", "status", "report"):
        sub = commands.add_parser(name)
        sub.add_argument("--log-dir", default=DEFAULT_DIR)
        if name == "run":
            sub.add_argument("--interval", type=positive_float, default=1.0)
            sub.add_argument("--retention-days", type=positive_int, default=2)
            sub.add_argument("--duration", type=positive_float, help="optional bounded foreground run, seconds")
        if name == "report":
            sub.add_argument("--boot-id", help="default: most recent retained previous boot; 'current' selects this boot")
            sub.add_argument("--minutes", type=positive_float, default=10)
            sub.add_argument("--no-journal", action="store_true")
    args = parser.parse_args()
    try:
        {"run": run, "status": status, "report": report}[args.command](args)
    except (OSError, ValueError) as exc:
        print("system-blackbox: %s" % exc, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
