"""Bounded measurements in disposable workers; never product acceptance."""
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import resource
import sys


GIB = 1024 ** 3
KERNEL = "Darwin Kernel Version 25.6.0: Fri Jul 31 19:16:43 PDT 2026; root:xnu-12377.161.14~5/RELEASE_ARM64_VMAPPLE"


def require(value, message):
    if not value:
        raise ValueError(message)


def case_specs():
    return ([dict(name="allocation-control", operation="allocation-control", kind="unlimited", index=0)]
            + [dict(name="control-" + operation, operation=operation, kind="control", index=0)
             for operation in ("deallocate", "overwrite", "protect")]
            + [dict(name=f"{kind}-{index}-{operation}", operation=operation, kind=kind, index=index)
               for kind, count in (("guard", 4), ("shared", 18)) for index in range(count)
               for operation in ("deallocate", "overwrite", "protect")]
            + [dict(name="limit-" + kind, operation="limits", kind=kind, index=0)
               for kind in ("direct", "exec-isolated", "exec-site")])


def emit(stage, **values):
    print("NGV_MEMORY " + json.dumps(dict(stage=stage, pid=os.getpid(), **values)), flush=True)


def selected_regions(rows, kind):
    if kind == "guard":
        return [r for r in rows if not r["isSubmap"] and r["protection"] == r["maxProtection"] == 0
                and r["shareMode"] == 3 and r["objectID"] == 0 and r["references"] == 0]
    if kind == "shared":
        return [r for r in rows if r["isSubmap"] and r["protection"] == r["maxProtection"] == 1]
    raise ValueError("unknown region class")


def immutable_candidate_bytes(rows, strict=True):
    guards, shared = (selected_regions(rows, kind) for kind in ("guard", "shared"))
    require(not strict or (len(guards), len(shared)) == (4, 18), "observed 22-region composition changed")
    return sum(r["bytes"] for r in guards + shared)


def coverage(rows, address, size):
    end = address + size
    selected = [r for r in rows if r["address"] < end and r["address"] + r["bytes"] > address]
    return dict(mappedBytes=sum(min(end, r["address"] + r["bytes"]) - max(address, r["address"])
                                for r in selected),
                writableBytes=sum(min(end, r["address"] + r["bytes"]) - max(address, r["address"])
                                  for r in selected if r["maxProtection"] & 2), regions=selected)


def inventory():
    path = Path(__file__).with_name("bpy_worker_sandbox_payload.py")
    spec = importlib.util.spec_from_file_location("ngv_memory_baseline", path)
    payload = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(payload)
    captured = []
    original = payload.emit_limit

    def record(stage, **values):
        captured.append(dict(stage=stage, **values))
        original(stage, **values)

    payload.emit_limit = record
    payload.post_failure_map()
    rows = [r for r in captured if r["stage"] == "map-region"]
    boundaries = [r for r in captured if r["stage"] == "boundary"]
    require(len(boundaries) == 1 and boundaries[0]["endpointsConfirmed"], "unstable map-size measurement")
    require(all(r["basic"]["sameRange"] for r in rows), "region interfaces disagree")
    total = sum(r["bytes"] for r in rows)
    require(total == boundaries[0]["acceptedBytes"], "map inventory changed during measurement")
    return rows, total


class Native:
    def __init__(self):
        self.lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        self.task = ctypes.c_uint32.in_dll(self.lib, "mach_task_self_").value
        require(self.task != 0, "own task port unavailable")
        self.deallocate = self.bind("mach_vm_deallocate", [ctypes.c_uint32, ctypes.c_uint64, ctypes.c_uint64])
        self.allocate = self.bind("mach_vm_allocate", [ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint64),
                                                       ctypes.c_uint64, ctypes.c_int])
        self.protect = self.bind("mach_vm_protect", [ctypes.c_uint32, ctypes.c_uint64, ctypes.c_uint64,
                                                    ctypes.c_int, ctypes.c_int])
        self.mmap = self.bind("mmap", [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int, ctypes.c_int,
                                      ctypes.c_int, ctypes.c_int64], ctypes.c_void_p)
        self.munmap = self.bind("munmap", [ctypes.c_void_p, ctypes.c_size_t])
        self.malloc = self.bind("malloc", [ctypes.c_size_t], ctypes.c_void_p)
        self.free = self.bind("free", [ctypes.c_void_p], None)

    def bind(self, name, arguments, result=ctypes.c_int):
        function = getattr(self.lib, name)
        function.argtypes, function.restype = arguments, result
        return function

    def temporary(self, size):
        address = ctypes.c_uint64()
        require(self.allocate(self.task, ctypes.byref(address), size, 1) == 0, "positive VM allocation failed")
        return address.value


def limit_paths(native, limited=True):
    outcomes = {}
    for size, label in ((1024 * 1024, "positive"), (7 * GIB, "over-budget")):
        pointer = native.malloc(size)
        outcomes[label + "-malloc"] = bool(pointer)
        if pointer:
            native.free(pointer)
        pointer = native.mmap(None, size, 0, 0x1002, -1, 0)
        accepted = pointer != ctypes.c_void_p(-1).value
        outcomes[label + "-mmap"] = accepted
        if accepted:
            require(native.munmap(pointer, size) == 0, "untouched mmap cleanup failed")
        address = ctypes.c_uint64()
        code = native.allocate(native.task, ctypes.byref(address), size, 1)
        outcomes[label + "-mach"] = code == 0
        if code == 0:
            require(native.deallocate(native.task, address.value, size) == 0, "untouched Mach allocation cleanup failed")
    emit("allocation-paths", outcomes=outcomes, explicitPayloadTouches=0)
    return all(value == (not limited or key.startswith("positive-")) for key, value in outcomes.items())


def run_case(config):
    case = config["memoryCase"]
    require(case in case_specs(), "unrecognized fixed diagnostic case")
    require(os.uname().version == KERNEL, "observed diagnostic kernel changed")
    require(sys.version_info[:3] == (3, 13, 15), "original Python identity changed")
    native = Native()
    if case["operation"] == "allocation-control":
        require(sys.argv[1:] == [] and resource.getrlimit(resource.RLIMIT_AS) == (resource.RLIM_INFINITY,) * 2,
                "unlimited allocation control requires original limits")
        emit("original-unlimited", limits=resource.getrlimit(resource.RLIMIT_AS))
        supported = limit_paths(native, limited=False)
        emit("complete", case=case, candidateSupported=supported,
             limits=resource.getrlimit(resource.RLIMIT_AS), runtimeAcceptance=False)
        return
    rows, total = inventory()
    exemptions = immutable_candidate_bytes(rows)
    after_exec = sys.argv[1:] == ["after-exec"]
    require(sys.argv[1:] in ([], ["after-exec"]), "unexpected diagnostic arguments")
    limit = exemptions + 6 * GIB
    if after_exec:
        require(case["operation"] == "limits" and case["kind"].startswith("exec-"), "unexpected exec continuation")
        expected = config["execLimit"]
        require(config["execPID"] == os.getpid() and resource.getrlimit(resource.RLIMIT_AS) == (expected, expected),
                "exec limit or execution identity changed")
        require(expected <= limit, "exec reduced candidate immutable baseline and enlarged usable allowance")
        limit = expected
    else:
        require(resource.getrlimit(resource.RLIMIT_AS) == (resource.RLIM_INFINITY,) * 2, "unexpected initial limits")
        resource.setrlimit(resource.RLIMIT_AS, (limit, limit))
        require(resource.getrlimit(resource.RLIMIT_AS) == (limit, limit), "candidate limit not installed")
    emit("candidate-limit", case=case, totalBytes=total, candidateExemptBytes=exemptions,
         limitBytes=limit, limits=resource.getrlimit(resource.RLIMIT_AS), afterExec=after_exec,
         qualification="candidate only; permanence not implied by flags")
    if case["operation"] == "limits":
        accepted = limit_paths(native)
        if case["kind"].startswith("exec-") and not after_exec:
            require(accepted, "allocation-path refusal failed before exec")
            config.update(execLimit=limit, execPID=os.getpid())
            Path("input.json").write_text(json.dumps(config))
            emit("before-exec", limitBytes=limit)
            flags = ["-I", "-B"] + (["-S"] if case["kind"] == "exec-isolated" else [])
            os.execv(sys.executable, [sys.executable, *flags, str(Path(__file__).resolve()), "after-exec"])
            raise RuntimeError("exec returned")
        emit("complete", case=case, candidateSupported=accepted, afterExec=after_exec,
             limits=resource.getrlimit(resource.RLIMIT_AS), runtimeAcceptance=False)
        return
    control = case["kind"] == "control"
    size = resource.getpagesize()
    if control:
        address = native.temporary(size)
    else:
        target = selected_regions(rows, case["kind"])[case["index"]]
        address = target["address"]
        if case["operation"] == "deallocate":
            size = target["bytes"]
    before = coverage(rows, address, size) if not control else None
    emit("before-operation", case=case, address=address, bytes=size, coverage=before)
    ctypes.set_errno(0)
    if case["operation"] == "deallocate":
        code = native.deallocate(native.task, address, size)
    elif case["operation"] == "protect":
        code = native.protect(native.task, address, size, 0, 3)
    else:
        pointer = native.mmap(address, size, 3, 0x1012, -1, 0)
        code = 0 if pointer == address else -1
        require(pointer in (address, ctypes.c_void_p(-1).value), "fixed mapping returned a different address")
    error = ctypes.get_errno()
    emit("operation-returned", code=code, errno=error)
    after_rows, after_total = inventory()
    after = coverage(after_rows, address, size)
    if control:
        supported = code == 0 and (after["mappedBytes"] == 0 if case["operation"] == "deallocate"
                                  else after["writableBytes"] == size)
    else:
        supported = after["mappedBytes"] == size and after["writableBytes"] == 0
        if case["operation"] != "deallocate":
            supported = supported and code != 0
        supported = supported and immutable_candidate_bytes(after_rows, strict=False) >= exemptions
    if control and case["operation"] != "deallocate":
        require(native.deallocate(native.task, address, size) == 0, "positive-control cleanup failed")
    supported = limit_paths(native) and supported
    emit("complete", case=case, candidateSupported=supported, beforeTotalBytes=total,
         afterTotalBytes=after_total, before=before, after=after, code=code, errno=error,
         limits=resource.getrlimit(resource.RLIMIT_AS), runtimeAcceptance=False)


def validate_case(case, records, pid):
    require(records and all(record.get("pid") == pid for record in records), "memory record PID mismatch")
    completed = [record for record in records if record.get("stage") == "complete"]
    require(len(completed) == 1 and completed[0].get("case") == case, "missing or duplicate case completion")
    require(completed[0].get("runtimeAcceptance") is False, "component cannot grant runtime acceptance")
    if case["operation"] == "allocation-control":
        originals = [r for r in records if r.get("stage") == "original-unlimited"]
        paths = [r for r in records if r.get("stage") == "allocation-paths"]
        require(len(originals) == len(paths) == 1
                and originals[0].get("limits") == [9223372036854775807] * 2
                and completed[0].get("limits") == originals[0]["limits"]
                and paths[0].get("outcomes") == {label + "-" + mechanism: True
                    for label in ("positive", "over-budget") for mechanism in ("malloc", "mmap", "mach")}
                and completed[0].get("candidateSupported") is True, "unlimited allocation positive control failed")
        return
    limits = [record for record in records if record.get("stage") == "candidate-limit"]
    executed = case["kind"].startswith("exec-")
    require(len(limits) == (2 if executed else 1), "candidate limit record count")
    for record in limits:
        require(record.get("case") == case and record.get("limits") == [record["limitBytes"]] * 2
                and record["totalBytes"] <= record["limitBytes"]
                and record["limitBytes"] <= record["candidateExemptBytes"] + 6 * GIB,
                "candidate limit evidence mismatch")
    require(completed[0].get("limits") == limits[-1]["limits"], "candidate limit changed during experiment")
    if executed:
        require(limits[0]["afterExec"] is False and limits[1]["afterExec"] is True
                and limits[0]["limitBytes"] == limits[1]["limitBytes"]
                and completed[0].get("afterExec") is True
                and len([r for r in records if r.get("stage") == "before-exec"]) == 1,
                "same-process exec enforcement evidence missing")
    paths = [r for r in records if r.get("stage") == "allocation-paths"]
    expected = {label + "-" + mechanism: label == "positive"
                for label in ("positive", "over-budget") for mechanism in ("malloc", "mmap", "mach")}
    require(len(paths) == (2 if executed else 1) and all(r.get("outcomes") == expected for r in paths),
            "positive or over-budget allocation observation failed")
    require(completed[0].get("candidateSupported") is True, "candidate exemption not supported by this case")


def main():
    for kind, value in ((resource.RLIMIT_CORE, 0), (resource.RLIMIT_FSIZE, 256 * 1024 * 1024),
                        (resource.RLIMIT_NOFILE, 256), (resource.RLIMIT_CPU, 120), (resource.RLIMIT_NPROC, 0)):
        resource.setrlimit(kind, (value, value))
    run_case(json.loads(Path("input.json").read_text()))


if __name__ == "__main__":
    main()
