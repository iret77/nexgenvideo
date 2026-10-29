"""Bounded measurements in disposable workers; never product acceptance."""
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import resource
import sys


GIB = 1024 ** 3
KERNEL = "Darwin Kernel Version 25.6.0: Fri Jul 31 19:16:43 PDT 2026; root:xnu-12377.161.14~5/RELEASE_ARM64_VMAPPLE"
ENVIRONMENT = dict(kernel=KERNEL, osBuild="25G83", imageVersion="20261021.0445.8", architecture="arm64")
ENVIRONMENT_POLICY = "macos26-arm64-same-run-kernel-build"
PREFLIGHT = dict(name="preflight", operation="preflight", kind="preflight", index=0)


class CandidateContradiction(ValueError):
    def __init__(self, message, target=None):
        super().__init__(message)
        self.target = target


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
                                  for r in selected if r["maxProtection"] & 2),
                currentWritableBytes=sum(min(end, r["address"] + r["bytes"]) - max(address, r["address"])
                                         for r in selected if r["protection"] & 2), regions=selected)


def inventory(measure_boundary=True):
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
    payload.post_failure_map(measure_boundary=measure_boundary)
    rows = [r for r in captured if r["stage"] == "map-region"]
    boundaries = [r for r in captured if r["stage"] == "boundary"]
    require(not measure_boundary or (len(boundaries) == 1 and boundaries[0]["endpointsConfirmed"]),
            "unstable map-size measurement")
    require(all(r["basic"]["sameRange"] for r in rows), "region interfaces disagree")
    total = sum(r["bytes"] for r in rows)
    require(not measure_boundary or total == boundaries[0]["acceptedBytes"], "map inventory changed during measurement")
    return rows, total


def candidate_regions(rows):
    immutable_candidate_bytes(rows)
    return [dict(kind=kind, address=r["address"], bytes=r["bytes"])
            for kind in ("guard", "shared") for r in selected_regions(rows, kind)]


def environment_observation(environment):
    version = plistlib.loads(Path("/System/Library/CoreServices/SystemVersion.plist").read_bytes())
    return dict(kernel=os.uname().version,
                osBuild=version["ProductBuildVersion"], productVersion=version["ProductVersion"],
                imageVersion=environment.get("ImageVersion"), architecture=os.uname().machine)


def environment_identity(observed):
    identity = {key: observed[key] for key in ("kernel", "osBuild", "productVersion", "architecture")}
    require(all(isinstance(value, str) and value for value in identity.values())
            and identity["productVersion"].startswith("26.") and identity["architecture"] == "arm64",
            "precondition mismatch: macOS26 arm64 identity")
    return identity


def validate_preflight(records, pid, environment):
    require(len(records) == 1 and records[0].get("stage") == "preflight"
            and records[0].get("pid") == pid and records[0].get("environment") == environment
            and records[0].get("pythonVersion") == [3, 13, 15] and records[0].get("pageBytes") == 16384,
            "precondition mismatch: interpreter identity")
    record = records[0]
    reference = candidate_regions(record["regions"])
    require(len({(r["address"], r["bytes"]) for r in reference}) == 22,
            "precondition mismatch: duplicate reference regions")
    require(sum(r["bytes"] for r in record["regions"]) == record["totalBytes"],
            "precondition mismatch: inventory total")
    return reference


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
        self.pidinfo = self.bind("proc_pidinfo", [ctypes.c_int, ctypes.c_int, ctypes.c_uint64,
                                                ctypes.c_void_p, ctypes.c_int])

    def bind(self, name, arguments, result=ctypes.c_int):
        function = getattr(self.lib, name)
        function.argtypes, function.restype = arguments, result
        return function

    def temporary(self, size):
        address = ctypes.c_uint64()
        require(self.allocate(self.task, ctypes.byref(address), size, 1) == 0, "positive VM allocation failed")
        return address.value

    def mapped_bytes(self):
        info = (ctypes.c_uint64 * 12)()
        require(self.pidinfo(os.getpid(), 4, 0, ctypes.byref(info), ctypes.sizeof(info)) == 96,
                "own virtual-size observation failed")
        return info[0]


def allocate_once(native, mechanism, size):
    if mechanism == "malloc":
        pointer = native.malloc(size)
        if pointer:
            native.free(pointer)
        return bool(pointer)
    if mechanism == "mmap":
        pointer = native.mmap(None, size, 0, 0x1002, -1, 0)
        accepted = pointer != ctypes.c_void_p(-1).value
        if accepted:
            require(native.munmap(pointer, size) == 0, "untouched mmap cleanup failed")
        return accepted
    require(mechanism == "mach", "unknown allocation mechanism")
    address = ctypes.c_uint64()
    code = native.allocate(native.task, ctypes.byref(address), size, 1)
    if code == 0:
        require(native.deallocate(native.task, address.value, size) == 0, "untouched Mach allocation cleanup failed")
    return code == 0


def headroom_paths(native, limit):
    observations = []
    page, margin = resource.getpagesize(), 16 * 1024 * 1024
    for mechanism in ("malloc", "mmap", "mach"):
        for label in ("within-headroom", "beyond-headroom"):
            total = native.mapped_bytes()
            headroom = limit - total
            size = ((headroom - margin) // page * page if label == "within-headroom"
                    else (headroom // page + 1) * page)
            require(size > 0 and headroom > margin, "insufficient observed allocation headroom")
            accepted = allocate_once(native, mechanism, size)
            observations.append(dict(mechanism=mechanism, label=label, totalBytes=total,
                                     bytes=size, accepted=accepted))
    emit("headroom-paths", limitBytes=limit, pageBytes=page, marginBytes=margin,
         observations=observations, explicitPayloadTouches=0,
         interpretation="6 GiB minus the non-candidate mapped baseline; not 6 GiB additional headroom")
    return all(r["accepted"] == (r["label"] == "within-headroom") for r in observations)


def limit_paths(native, limited=True):
    outcomes = {}
    for size, label in ((1024 * 1024, "positive"), (7 * GIB, "over-budget")):
        for mechanism in ("malloc", "mmap", "mach"):
            outcomes[label + "-" + mechanism] = allocate_once(native, mechanism, size)
    emit("allocation-paths", outcomes=outcomes, explicitPayloadTouches=0)
    return all(value == (not limited or key.startswith("positive-")) for key, value in outcomes.items())


def run_case(config):
    case = config["memoryCase"]
    require(case in case_specs() or case == PREFLIGHT, "unrecognized fixed diagnostic case")
    environment = environment_identity(environment_observation(os.environ))
    require(environment == config["runtimeEnvironment"], "precondition mismatch: same-run environment changed")
    require(sys.version_info[:3] == (3, 13, 15), "original Python identity changed")
    if case == PREFLIGHT:
        rows, total = inventory(measure_boundary=False)
        immutable_candidate_bytes(rows)
        emit("preflight", environment=environment, pythonVersion=list(sys.version_info[:3]),
             regions=rows, totalBytes=total, pageBytes=resource.getpagesize())
        return
    native = Native()
    emit("case-environment", environment=environment, case=case)
    if case["operation"] == "allocation-control":
        require(sys.argv[1:] == [] and resource.getrlimit(resource.RLIMIT_AS) == (resource.RLIM_INFINITY,) * 2,
                "unlimited allocation control requires original limits")
        emit("original-unlimited", limits=resource.getrlimit(resource.RLIMIT_AS))
        supported = limit_paths(native, limited=False)
        emit("complete", case=case, candidateSupported=supported,
             limits=resource.getrlimit(resource.RLIMIT_AS), runtimeAcceptance=False)
        return
    after_exec = sys.argv[1:] == ["after-exec"]
    require(sys.argv[1:] in ([], ["after-exec"]), "unexpected diagnostic arguments")
    if after_exec:
        require(case["operation"] == "limits" and case["kind"].startswith("exec-"), "unexpected exec continuation")
        expected = config["execLimit"]
        require(config["execPID"] == os.getpid() and resource.getrlimit(resource.RLIMIT_AS) == (expected, expected),
                "exec limit or execution identity changed")
        emit("after-exec-before-setrlimit", limitBytes=expected, limits=resource.getrlimit(resource.RLIMIT_AS))
        accepted = limit_paths(native)
        accepted = headroom_paths(native, expected) and accepted
    rows, total = inventory()
    exemptions = immutable_candidate_bytes(rows)
    reference = candidate_regions(rows)
    require(reference == config["referenceRegions"], "precondition mismatch: candidate regions changed")
    limit = exemptions + 6 * GIB
    if after_exec:
        require(expected <= limit, "exec reduced candidate immutable baseline and enlarged usable allowance")
        limit = expected
    else:
        require(resource.getrlimit(resource.RLIMIT_AS) == (resource.RLIM_INFINITY,) * 2, "unexpected initial limits")
        resource.setrlimit(resource.RLIMIT_AS, (limit, limit))
        require(resource.getrlimit(resource.RLIMIT_AS) == (limit, limit), "candidate limit not installed")
    emit("candidate-limit", case=case, totalBytes=total, candidateExemptBytes=exemptions,
         limitBytes=limit, limits=resource.getrlimit(resource.RLIMIT_AS), afterExec=after_exec,
         candidateRegions=reference, nonCandidateBaselineBytes=total - exemptions,
         observedHeadroomBytes=limit - total,
         qualification="candidate only; permanence not implied by flags")
    if case["operation"] == "limits":
        if not after_exec:
            accepted = limit_paths(native)
            accepted = headroom_paths(native, limit) and accepted
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
        if case["operation"] == "protect":
            require(native.protect(native.task, address, size, 1, 1) == 0, "readonly maximum setup failed")
        rows, _ = inventory(measure_boundary=False)
    else:
        target = selected_regions(rows, case["kind"])[case["index"]]
        address = target["address"]
        if case["operation"] == "deallocate":
            size = target["bytes"]
    before = coverage(rows, address, size)
    emit("before-operation", case=case, address=address, bytes=size, coverage=before)
    ctypes.set_errno(0)
    if case["operation"] == "deallocate":
        code = native.deallocate(native.task, address, size)
    elif case["operation"] == "protect":
        code = native.protect(native.task, address, size, 0, 0x13)
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
                                  else after["currentWritableBytes"] == after["writableBytes"] == size)
    else:
        supported = after["mappedBytes"] == size and after["writableBytes"] == 0
        if case["operation"] != "deallocate":
            supported = supported and code != 0
        supported = supported and all(coverage(after_rows, r["address"], r["bytes"])["mappedBytes"] == r["bytes"]
                                      and coverage(after_rows, r["address"], r["bytes"])["writableBytes"] == 0
                                      for r in reference)
    if control and case["operation"] != "deallocate":
        require(native.deallocate(native.task, address, size) == 0, "positive-control cleanup failed")
    supported = limit_paths(native) and supported
    emit("complete", case=case, candidateSupported=supported, beforeTotalBytes=total,
         afterTotalBytes=after_total, before=before, after=after, code=code, errno=error,
         afterCandidateRegions=[dict(kind=kind, address=r["address"], bytes=r["bytes"])
                                for kind in ("guard", "shared") for r in selected_regions(after_rows, kind)],
         limits=resource.getrlimit(resource.RLIMIT_AS), runtimeAcceptance=False)


def parse_observations(text):
    records = []
    for line in text.splitlines():
        for prefix, channel in (("NGV_MEMORY ", "memory"), ("NGV_LIMIT ", "limit")):
            if line.startswith(prefix):
                record = json.loads(line[len(prefix):])
                record["channel"] = channel
                records.append(record)
    return records


def inventory_at(observations, event, pid):
    stop = next(i for i, row in enumerate(observations) if row is event)
    ends = [i for i, row in enumerate(observations[:stop])
            if row.get("channel") == "limit" and row.get("stage") == "map-end"]
    require(ends, "missing full inventory before operation observation")
    end = ends[-1]
    starts = [i for i, row in enumerate(observations[:end])
              if row.get("channel") == "limit" and row.get("stage") == "post-ctypes-task"]
    require(starts, "missing full inventory start")
    rows = observations[starts[-1] + 1:end]
    require(rows and all(r.get("channel") == "limit" and r.get("stage") == "map-region"
                        and r.get("pid") == pid and r.get("index") == i
                        for i, r in enumerate(rows)), "incomplete full inventory")
    closing = observations[end]
    require(closing.get("pid") == pid and closing.get("endCode") == 1
            and closing.get("regions") == len(rows)
            and closing.get("topLevelBytes") == sum(r["bytes"] for r in rows), "inventory closure mismatch")
    return rows


def full_coverage(rows, address, size):
    require(type(address) is int and type(size) is int and address >= 0 and size > 0, "invalid interval")
    end, cursor, mapped, maximum, current = address + size, 0, 0, 0, 0
    selected = []
    for row in rows:
        start, length = row["address"], row["bytes"]
        require(type(start) is int and type(length) is int and start >= cursor and length > 0,
                "overlapping or invalid inventory ranges")
        cursor = start + length
        lo, hi = max(start, address), min(cursor, end)
        if hi > lo:
            mapped += hi - lo
            maximum += (hi - lo) if row["maxProtection"] & 2 else 0
            current += (hi - lo) if row["protection"] & 2 else 0
            selected.append({k: v for k, v in row.items() if k not in ("pid", "channel", "stage")})
    return dict(mappedBytes=mapped, writableBytes=maximum, currentWritableBytes=current, regions=selected)


def retention_state(before, after):
    reduced = (any(r["protection"] or r["maxProtection"] for r in before["regions"])
               and all(r["protection"] == r["maxProtection"] == 0 for r in after["regions"]))
    return "retained-with-reduced-protection" if reduced else "retained"


def normalize_coverage(value):
    return dict(value, regions=[{k: v for k, v in r.items() if k not in ("pid", "channel", "stage")}
                               for r in value["regions"]])


def validate_headroom(record, limit):
    require(record["limitBytes"] == limit and record["pageBytes"] == 16384
            and record["marginBytes"] == 16 * 1024 * 1024 and record["explicitPayloadTouches"] == 0,
            "headroom measurement identity")
    rows = record["observations"]
    expected = [(mechanism, label) for mechanism in ("malloc", "mmap", "mach")
                for label in ("within-headroom", "beyond-headroom")]
    require([(r["mechanism"], r["label"]) for r in rows] == expected, "headroom path coverage")
    for r in rows:
        headroom = limit - r["totalBytes"]
        inside = r["label"] == "within-headroom"
        size = ((headroom - record["marginBytes"]) // record["pageBytes"] * record["pageBytes"] if inside
                else (headroom // record["pageBytes"] + 1) * record["pageBytes"])
        require(headroom > record["marginBytes"] and r["bytes"] == size
                and type(r["accepted"]) is bool, "invalid headroom boundary evidence")
    return all(r["accepted"] == (r["label"] == "within-headroom") for r in rows)


def validate_case(case, observations, pid, reference, environment):
    def position(record):
        return next(i for i, observed in enumerate(observations) if observed is record)

    records = [r for r in observations if r.get("channel", "memory") == "memory"]
    require(records and all(record.get("pid") == pid for record in records), "memory record PID mismatch")
    identities = [r for r in records if r.get("stage") == "case-environment"]
    require(len(identities) == (2 if case["kind"].startswith("exec-") else 1)
            and all(r.get("case") == case and r.get("environment") == environment for r in identities),
            "same-run environment evidence missing")
    completed = [record for record in records if record.get("stage") == "complete"]
    require(len(completed) == 1 and completed[0].get("case") == case, "missing or duplicate case completion")
    require(completed[0].get("runtimeAcceptance") is False, "component cannot grant runtime acceptance")
    require(records[-1] == completed[0], "completion must be the final memory record")
    paths = [r for r in records if r.get("stage") == "allocation-paths"]
    if case["operation"] == "allocation-control":
        originals = [r for r in records if r.get("stage") == "original-unlimited"]
        require(len(originals) == len(paths) == 1
                and originals[0].get("limits") == [9223372036854775807] * 2
                and completed[0].get("limits") == originals[0]["limits"]
                and paths[0].get("outcomes") == {label + "-" + mechanism: True
                    for label in ("positive", "over-budget") for mechanism in ("malloc", "mmap", "mach")}
                and completed[0].get("candidateSupported") is True, "unlimited allocation positive control failed")
        return None
    limits = [record for record in records if record.get("stage") == "candidate-limit"]
    executed = case["kind"].startswith("exec-")
    require(len(limits) == (2 if executed else 1), "candidate limit record count")
    exempt = sum(r["bytes"] for r in reference)
    for record in limits:
        require(record.get("case") == case and record.get("limits") == [record["limitBytes"]] * 2
                and record["totalBytes"] <= record["limitBytes"]
                and record["candidateExemptBytes"] == exempt and record["candidateRegions"] == reference
                and record["nonCandidateBaselineBytes"] == record["totalBytes"] - exempt
                and record["observedHeadroomBytes"] == record["limitBytes"] - record["totalBytes"]
                and record["limitBytes"] == exempt + 6 * GIB,
                "candidate limit evidence mismatch")
    require(completed[0].get("limits") == limits[-1]["limits"], "candidate limit changed during experiment")
    expected = {label + "-" + mechanism: label == "positive"
                for label in ("positive", "over-budget") for mechanism in ("malloc", "mmap", "mach")}
    require(len(paths) == (2 if executed else 1)
            and all(set(r.get("outcomes", {})) == set(expected)
                    and all(type(value) is bool for value in r["outcomes"].values()) for r in paths),
            "incomplete allocation observation")
    allocation_supported = all(r["outcomes"] == expected for r in paths)
    headroom_supported = True
    if case["operation"] == "limits":
        brackets = [r for r in records if r.get("stage") == "headroom-paths"]
        require(len(brackets) == len(paths), "missing headroom measurements")
        for bracket in brackets:
            headroom_supported = validate_headroom(bracket, limits[0]["limitBytes"]) and headroom_supported
    if executed:
        before = [i for i, r in enumerate(observations) if r.get("stage") == "before-exec"]
        after = [i for i, r in enumerate(observations) if r.get("stage") == "after-exec-before-setrlimit"]
        require(len(before) == len(after) == 1, "missing exec markers")
        allocation_at = position(paths[1])
        bracket_at = position(brackets[1])
        require(position(limits[0]) < position(paths[0])
                < position(brackets[0]) < before[0] < after[0] < allocation_at < bracket_at
                < position(limits[1]) < position(completed[0]),
                "exec allocation observations must precede inventory")
        require(not any(r.get("channel") == "limit" or r.get("stage", "").startswith("boundary")
                        for r in observations[before[0] + 1:bracket_at]),
                "exec allocation observation contaminated by limit inventory")
        require(observations[after[0]].get("limits") == limits[0]["limits"]
                and observations[before[0]].get("limitBytes") == limits[0]["limitBytes"]
                and limits[0]["afterExec"] is False and limits[1]["afterExec"] is True
                and completed[0].get("afterExec") is True, "same-process exec enforcement evidence missing")
    target_key = None
    if case["operation"] in ("deallocate", "overwrite", "protect"):
        before = [r for r in records if r.get("stage") == "before-operation"]
        returned = [r for r in records if r.get("stage") == "operation-returned"]
        require(len(before) == len(returned) == 1 and before[0]["case"] == case,
                "missing operation evidence")
        before = before[0]
        result = completed[0]
        address, size = before["address"], before["bytes"]
        require(records.index(limits[0]) < records.index(before) < records.index(returned[0])
                < records.index(paths[0]) < records.index(result), "operation record order")
        before_rows = inventory_at(observations, before, pid)
        after_rows = inventory_at(observations, paths[0], pid)
        require(position(returned[0]) < max(i for i, r in enumerate(observations[:position(paths[0])])
                if r.get("channel") == "limit" and r.get("stage") == "post-ctypes-task"),
                "after-operation inventory missing")
        for field, raw, rows in (("before", before["coverage"], before_rows),
                                 ("after", result["after"], after_rows)):
            measured = full_coverage(rows, address, size)
            require(measured == normalize_coverage(raw) and result[field] == raw,
                    "region coverage summary differs from full inventory")
        require(result["code"] == returned[0]["code"] and result["errno"] == returned[0]["errno"],
                "operation return evidence mismatch")
        original, after = before["coverage"], result["after"]
        require(original["mappedBytes"] == size, "target not fully mapped before operation")
        if case["kind"] == "control":
            require(size == 16384 and result["code"] == 0, "positive region control failed")
            if case["operation"] == "deallocate":
                require(after["mappedBytes"] == 0, "deallocation control did not remove mapping")
            else:
                require(after["mappedBytes"] == after["currentWritableBytes"] == after["writableBytes"] == size,
                        "positive control did not make mapping writable")
            if case["operation"] == "protect":
                require(original["writableBytes"] == original["currentWritableBytes"] == 0
                        and all(r["maxProtection"] == r["protection"] == 1 for r in original["regions"]),
                        "copy-protection control was not initially readonly")
        else:
            target = [r for r in reference if r["kind"] == case["kind"]][case["index"]]
            require(address == target["address"]
                    and size == (target["bytes"] if case["operation"] == "deallocate" else 16384),
                    "case target differs from reference inventory")
            target_key = (address, target["bytes"])
            retained = [full_coverage(after_rows, r["address"], r["bytes"]) for r in reference]
            supported = (original["writableBytes"] == after["writableBytes"] == after["currentWritableBytes"] == 0
                         and after["mappedBytes"] == size
                         and (case["operation"] == "deallocate" or result["code"] != 0)
                         and all(measured["mappedBytes"] == r["bytes"]
                                 and measured["writableBytes"] == measured["currentWritableBytes"] == 0
                                 for r, measured in zip(reference, retained)))
            if not supported:
                raise CandidateContradiction("candidate region observation contradicts mapping/protection requirements", target_key)
    if not allocation_supported or not headroom_supported:
        raise CandidateContradiction("allocation observations contradict the candidate limit", target_key)
    require(completed[0].get("candidateSupported") is True, "worker summary contradicts raw observations")
    return target_key



def main():
    for kind, value in ((resource.RLIMIT_CORE, 0), (resource.RLIMIT_FSIZE, 256 * 1024 * 1024),
                        (resource.RLIMIT_NOFILE, 256), (resource.RLIMIT_CPU, 120), (resource.RLIMIT_NPROC, 0)):
        resource.setrlimit(kind, (value, value))
    run_case(json.loads(Path("input.json").read_text()))


if __name__ == "__main__":
    main()
