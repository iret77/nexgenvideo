"""Read activation and memory evidence for one owned App test host."""
import ctypes
import json
import os
from pathlib import Path
import struct
import sys
import threading
import time
import uuid


def diagnostic_key(key):
    return (key.startswith((b"MTL_", b"Malloc", b"OBJC_DEBUG_", b"NSZombie", b"DYLD_PRINT_"))
            or key in {b"NSDeallocateZombies", b"METAL_DEVICE_WRAPPER_TYPE", b"DYLD_INSERT_LIBRARIES"})


def profile_switch(profile):
    if profile == "zombies":
        return "NSZombieEnabled", "YES"
    if profile == "glow-reproduction":
        return "DYLD_PRINT_LIBRARIES", "1"
    raise ValueError("Unknown owned App diagnostic profile")


def diagnostic_environment(environment, profile):
    if any(diagnostic_key(key.encode()) for key in environment):
        raise ValueError("Another memory or Metal diagnostic is already configured")
    key, value = profile_switch(profile)
    return dict(environment, **{key: value})


def zombie_environment(environment):
    return diagnostic_environment(environment, "zombies")


def selected_environment(data, command, profile="zombies"):
    if len(data) < 5:
        raise ValueError("Incomplete process argument header")
    argc = struct.unpack_from("=i", data)[0]
    if argc != len(command) or not 0 < argc <= 8192:
        raise ValueError("Actual process argument count differs")
    cursor = 4

    def string():
        nonlocal cursor
        end = data.find(b"\0", cursor)
        if end < 0:
            raise ValueError("Unterminated process argument data")
        value = data[cursor:end]
        cursor = end + 1
        return value

    if string() != os.fsencode(command[0]):
        raise ValueError("Actual process executable differs")
    while cursor < len(data) and data[cursor] == 0:
        cursor += 1
    if [string() for _ in range(argc)] != [os.fsencode(value) for value in command]:
        raise ValueError("Actual process arguments differ")
    selected = []
    while cursor < len(data):
        entry = string()
        key, separator, value = entry.partition(b"=")
        if separator and diagnostic_key(key):
            selected.append((key, value))
    key, value = profile_switch(profile)
    if selected != [(key.encode(), value.encode())]:
        raise ValueError("Actual process does not have the sole requested diagnostic")
    return {key: value, "otherDiagnosticVariablesPresent": False}


class RUsageV4(ctypes.Structure):
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups", "ri_pageins",
        "ri_wired_size", "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime", "ri_proc_exit_abstime",
        "ri_child_user_time", "ri_child_system_time", "ri_child_pkg_idle_wkups", "ri_child_interrupt_wkups",
        "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread", "ri_diskio_byteswritten",
        "ri_cpu_time_qos_default", "ri_cpu_time_qos_maintenance", "ri_cpu_time_qos_background",
        "ri_cpu_time_qos_utility", "ri_cpu_time_qos_legacy", "ri_cpu_time_qos_user_initiated",
        "ri_cpu_time_qos_user_interactive", "ri_billed_system_time", "ri_serviced_system_time", "ri_logical_writes",
        "ri_lifetime_max_phys_footprint", "ri_instructions", "ri_cycles", "ri_billed_energy", "ri_serviced_energy",
        "ri_interval_max_phys_footprint", "ri_runnable_time")]


class NativeReader:
    def __init__(self):
        if sys.platform != "darwin":
            raise OSError("Owned process diagnostics require macOS")
        self.libc = ctypes.CDLL(None, use_errno=True)
        self.libc.sysctl.argtypes = [ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
                                     ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t]
        self.libc.sysctl.restype = ctypes.c_int
        self.libc.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        self.libc.proc_pid_rusage.restype = ctypes.c_int

    def arguments(self, pid):
        mib = (ctypes.c_int * 3)(1, 49, pid)
        size = ctypes.c_size_t()
        if self.libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0):
            raise OSError(ctypes.get_errno(), "Cannot size owned process arguments")
        if not 4 < size.value <= 1024 * 1024:
            raise ValueError("Owned process arguments exceed the diagnostic bound")
        buffer = ctypes.create_string_buffer(size.value)
        if self.libc.sysctl(mib, 3, buffer, ctypes.byref(size), None, 0):
            raise OSError(ctypes.get_errno(), "Cannot read owned process arguments")
        try:
            return bytes(buffer[:size.value])
        finally:
            ctypes.memset(buffer, 0, len(buffer))

    def usage(self, pid):
        value = RUsageV4()
        if self.libc.proc_pid_rusage(pid, 4, ctypes.byref(value)):
            raise OSError(ctypes.get_errno(), "Cannot read owned process usage")
        return {"imageUUID": str(uuid.UUID(bytes=bytes(value.ri_uuid))),
                "startAbsoluteTime": value.ri_proc_start_abstime,
                "exitAbsoluteTime": value.ri_proc_exit_abstime,
                "residentBytes": value.ri_resident_size,
                "lifetimePeakPhysicalFootprintBytes": value.ri_lifetime_max_phys_footprint}


class ZombieCapture:
    def __init__(self, pid, command, identity, folder, source_sha, reader=None, profile="zombies"):
        profile_switch(profile)
        self.profile = profile
        if identity.get("hostExecutable") != command[0]:
            raise ValueError("Observed host and launched executable differ")
        self.pid = pid
        self.command = command
        self.folder = Path(folder)
        self.identity = dict(identity, hostUUID=str(uuid.UUID(identity["hostUUID"])))
        self.reader = reader
        self.stop = threading.Event()
        self.thread = None
        self.receipt = {"schema": 1, "profile": profile, "status": "unavailable", "pid": pid,
                        "parentPID": os.getpid(), "sourceSHA": source_sha,
                        "harnessSourceSHA": source_sha, "productSourceSHA": identity.get("productSourceSHA"),
                        "hostUUID": self.identity["hostUUID"], "hostSHA256": identity["hostSHA256"],
                        "environmentMethod": "sysctl KERN_PROCARGS2; selected fields only",
                        "memoryMethod": "proc_pid_rusage RUSAGE_INFO_V4", "sampleCount": 0,
                        "memoryErrors": [], "lifetimePeakPhysicalFootprintBytes": 0,
                        "maximumObservedResidentBytes": 0}

    def write(self):
        path = self.folder / ("zombie-diagnostic.json" if self.profile == "zombies" else "glow-diagnostic.json")
        temporary = path.with_suffix(".pending")
        temporary.write_text(json.dumps(self.receipt, indent=2) + "\n")
        temporary.replace(path)

    def sample(self):
        value = self.reader.usage(self.pid)
        if (str(uuid.UUID(value["imageUUID"])) != self.identity["hostUUID"] or value["startAbsoluteTime"] <= 0
                or value["startAbsoluteTime"] != self.receipt.get("startAbsoluteTime", value["startAbsoluteTime"])):
            self.receipt["status"] = "identity-mismatch"
            self.stop.set()
            raise ValueError("Owned host usage identity differs")
        self.receipt["startAbsoluteTime"] = value["startAbsoluteTime"]
        self.receipt["sampleCount"] += 1
        self.receipt["lastSampleAt"] = time.time()
        self.receipt["lastProcessExitAbsoluteTime"] = value.get("exitAbsoluteTime", 0)
        self.receipt["maximumObservedResidentBytes"] = max(
            self.receipt["maximumObservedResidentBytes"], value["residentBytes"])
        self.receipt["lifetimePeakPhysicalFootprintBytes"] = max(
            self.receipt["lifetimePeakPhysicalFootprintBytes"], value["lifetimePeakPhysicalFootprintBytes"])

    def start(self):
        try:
            self.reader = self.reader or NativeReader()
            self.sample()
            self.receipt["environment"] = selected_environment(self.reader.arguments(self.pid), self.command, self.profile)
            self.sample()
            self.receipt["status"] = "verified"
            self.write()
            thread = threading.Thread(target=self.monitor, daemon=True)
            thread.start()
            self.thread = thread
        except Exception as error:
            self.receipt.update(status="unavailable", errorType=type(error).__name__, errno=getattr(error, "errno", None))
            self.write()

    def monitor(self):
        while not self.stop.wait(1):
            try:
                self.sample()
                self.write()
            except Exception as error:
                self.receipt["memoryErrors"].append({"errorType": type(error).__name__, "errno": getattr(error, "errno", None)})
                if self.receipt["status"] == "verified":
                    self.receipt["status"] = "memory-unavailable"
                return

    def finish(self):
        self.stop.set()
        if self.thread is not None:
            self.thread.join()
        if self.receipt["status"] == "verified":
            try:
                self.sample()
            except Exception as error:
                self.receipt["memoryErrors"].append({"errorType": type(error).__name__, "errno": getattr(error, "errno", None)})
                if self.receipt["status"] == "verified":
                    self.receipt["status"] = "memory-unavailable"
        self.receipt["finishedAt"] = time.time()
        self.receipt["peakScope"] = "Kernel lifetime physical-footprint peak through lastSampleAt, before wait/reap"
        self.write()
        return self.receipt
