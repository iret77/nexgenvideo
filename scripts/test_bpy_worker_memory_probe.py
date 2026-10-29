from copy import deepcopy
import ctypes
import unittest
import json
import plistlib
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import bpy_worker_memory_probe as memory
import bpy_worker_sandbox_probe as probe
from bpy_worker_sandbox_probe import memory_mode


class MemoryObservationTests(unittest.TestCase):
    def test_full_observed_inventory_is_covered_not_only_four_largest_submaps(self):
        cases = memory.case_specs()
        self.assertEqual(len(cases), 73)
        self.assertEqual(len({case["name"] for case in cases}), 73)
        for operation in ("deallocate", "overwrite", "protect"):
            targets = {(case["kind"], case["index"]) for case in cases
                       if case["operation"] == operation and case["kind"] != "control"}
            self.assertEqual(targets, {("guard", index) for index in range(4)}
                             | {("shared", index) for index in range(18)})

    def environment(self):
        return dict(kernel=memory.KERNEL, osBuild="25G83", productVersion="26.6.2", architecture="arm64")

    def reference(self):
        return [dict(kind=kind, address=(index + offset) * memory.GIB, bytes=memory.GIB)
                for kind, count, offset in (("guard", 4, 100), ("shared", 18, 200)) for index in range(count)]

    def headroom(self, limit):
        return dict(stage="headroom-paths", pid=42, limitBytes=limit, pageBytes=16384,
                    marginBytes=16 * 1024 * 1024, explicitPayloadTouches=0,
                    observations=[dict(mechanism=mechanism, label=label, totalBytes=limit-5*memory.GIB,
                                       bytes=5*memory.GIB - 16*1024*1024 if label == "within-headroom" else 5*memory.GIB+16384,
                                       accepted=label == "within-headroom")
                                  for mechanism in ("malloc", "mmap", "mach")
                                  for label in ("within-headroom", "beyond-headroom")])

    def evidence(self, kind="direct"):
        case = next(c for c in memory.case_specs() if c["kind"] == kind)
        limit = 28 * memory.GIB
        first = dict(stage="candidate-limit", pid=42, case=case, limitBytes=limit,
                     limits=[limit, limit], totalBytes=23 * memory.GIB,
                     candidateExemptBytes=22 * memory.GIB, afterExec=False,
                     candidateRegions=self.reference(), nonCandidateBaselineBytes=memory.GIB,
                     observedHeadroomBytes=5 * memory.GIB)
        paths = dict(stage="allocation-paths", pid=42, outcomes={label + "-" + mechanism: label == "positive"
                     for label in ("positive", "over-budget") for mechanism in ("malloc", "mmap", "mach")})
        records = [first, paths, self.headroom(limit)]
        if kind.startswith("exec-"):
            records += [dict(stage="before-exec", pid=42, limitBytes=limit),
                        dict(stage="after-exec-before-setrlimit", pid=42, limits=[limit, limit]),
                        deepcopy(paths), self.headroom(limit), dict(first, afterExec=True)]
        records += [dict(stage="case-environment", pid=42, case=case, environment=self.environment())
                    for _ in range(2 if kind.startswith("exec-") else 1)]
        records.append(dict(stage="complete", pid=42, case=case, candidateSupported=True,
                            afterExec=kind.startswith("exec-"), limits=[limit, limit], runtimeAcceptance=False))
        return case, records

    def test_direct_and_both_exec_variants_require_positive_and_negative_observations(self):
        for kind in ("direct", "exec-isolated", "exec-site"):
            case, records = self.evidence(kind)
            memory.validate_case(case, records, 42, self.reference(), self.environment())

    def test_wrong_pid_duplicate_or_unproved_completion_is_rejected(self):
        case, baseline = self.evidence()
        for change in (lambda r: r[0].update(pid=43), lambda r: r.append(deepcopy(r[-1])),
                       lambda r: r[-1].update(candidateSupported=False),
                       lambda r: r[-1].update(runtimeAcceptance=True), lambda r: r.pop(),
                       lambda r: r[-1].update(limits=[1, 1])):
            records = deepcopy(baseline)
            change(records)
            with self.assertRaises(ValueError):
                memory.validate_case(case, records, 42, self.reference(), self.environment())

    def test_reclaimed_baseline_cannot_enlarge_reported_usable_budget(self):
        case, records = self.evidence("exec-site")
        next(r for r in records if r.get("stage") == "candidate-limit" and r["afterExec"])["candidateExemptBytes"] -= memory.GIB
        with self.assertRaises(ValueError):
            memory.validate_case(case, records, 42, self.reference(), self.environment())

    def test_missing_post_exec_observation_cannot_pass(self):
        case, records = self.evidence("exec-isolated")
        records.remove(next(r for r in records if r.get("stage") == "candidate-limit" and r["afterExec"]))
        with self.assertRaises(ValueError):
            memory.validate_case(case, records, 42, self.reference(), self.environment())

    def test_any_accepted_large_allocation_or_failed_positive_control_rejects_candidate(self):
        for mechanism in ("malloc", "mmap", "mach"):
            for label in ("positive", "over-budget"):
                case, records = self.evidence()
                key = label + "-" + mechanism
                records[1]["outcomes"][key] = not records[1]["outcomes"][key]
                with self.assertRaises(ValueError):
                    memory.validate_case(case, records, 42, self.reference(), self.environment())

    def test_mutable_and_object_backed_regions_are_not_exempt(self):
        guard = dict(address=0, bytes=16384, isSubmap=0, protection=0, maxProtection=0,
                     shareMode=3, objectID=0, references=0)
        self.assertEqual(memory.selected_regions([guard], "guard"), [guard])
        for field, value in (("maxProtection", 2), ("protection", 1), ("objectID", 1),
                             ("references", 1), ("isSubmap", 1), ("shareMode", 2)):
            self.assertEqual(memory.selected_regions([dict(guard, **{field: value})], "guard"), [])
        self.assertEqual(memory.selected_regions([dict(guard, isSubmap=1, protection=1, maxProtection=3)], "shared"), [])

    def test_split_mapping_coverage_counts_holes_and_writable_pages(self):
        rows = [dict(address=100, bytes=20, maxProtection=0, protection=0),
                dict(address=130, bytes=20, maxProtection=3, protection=3)]
        value = memory.coverage(rows, 110, 30)
        self.assertEqual(value["mappedBytes"], 20)
        self.assertEqual(value["writableBytes"], 10)

    def test_memory_mode_cannot_build_new_helper_or_silently_select_itself(self):
        self.assertFalse(memory_mode({}))
        self.assertTrue(memory_mode(dict(NGV_SANDBOX_MEMORY_PROBE="true", NGV_SANDBOX_RESUME_PYTHON="true")))
        for environment in (dict(NGV_SANDBOX_MEMORY_PROBE="true"), dict(NGV_SANDBOX_MEMORY_PROBE="1")):
            with self.assertRaises(ValueError):
                memory_mode(environment)

    def test_unexpected_large_allocations_are_released_and_reported_as_failure(self):
        native = Mock()
        native.malloc.return_value = 1234
        native.mmap.return_value = 4096
        native.munmap.return_value = native.deallocate.return_value = 0

        def allocate(_task, address, _size, _flags):
            ctypes.cast(address, ctypes.POINTER(ctypes.c_uint64))[0] = 8192
            return 0

        native.allocate.side_effect = allocate
        with patch.object(memory, "emit"):
            self.assertFalse(memory.limit_paths(native))
        self.assertEqual(native.free.call_count, 2)
        self.assertEqual(native.munmap.call_count, 2)
        self.assertEqual(native.deallocate.call_count, 2)

    def test_failed_cleanup_is_never_a_denial_pass(self):
        native = Mock()
        native.malloc.return_value = None
        native.mmap.return_value = 4096
        native.munmap.return_value = -1
        with patch.object(memory, "emit"), self.assertRaisesRegex(ValueError, "cleanup"):
            memory.limit_paths(native)

    def test_exec_rejects_boundary_probe_before_allocation_even_with_success_flags(self):
        for kind in ("exec-isolated", "exec-site"):
            case, records = self.evidence(kind)
            records.insert(5, dict(channel="limit", stage="boundary-attempt", pid=42))
            with self.assertRaisesRegex(ValueError, "contaminated"):
                memory.validate_case(case, records, 42, self.reference(), self.environment())

    def test_parser_preserves_boundary_events_between_memory_events(self):
        rows = [dict(stage="before-exec", pid=42), dict(stage="boundary-attempt", pid=42),
                dict(stage="allocation-paths", pid=42)]
        text = "\n".join(prefix + json.dumps(row) for prefix, row in zip(
            ("NGV_MEMORY ", "NGV_LIMIT ", "NGV_MEMORY "), rows))
        self.assertEqual([r["channel"] for r in memory.parse_observations(text)], ["memory", "limit", "memory"])

    def test_exec_worker_probes_allocations_before_any_inventory_or_as_setter(self):
        case, _ = self.evidence("exec-site")
        events = []
        limit = 28 * memory.GIB
        rows = [dict(r, isSubmap=int(r["kind"] == "shared"),
                     protection=int(r["kind"] == "shared"), maxProtection=int(r["kind"] == "shared"),
                     shareMode=3, objectID=0, references=0) for r in self.reference()]
        def inventory():
            events.append("inventory")
            return rows, 23 * memory.GIB
        with patch.object(memory.os, "uname", return_value=SimpleNamespace(version=memory.KERNEL)), \
             patch.object(memory.sys, "version_info", (3, 13, 15)), \
             patch.object(memory.sys, "argv", ["probe", "after-exec"]), \
             patch.object(memory.os, "getpid", return_value=42), patch.object(memory, "Native"), \
             patch.object(memory, "environment_observation", return_value=self.environment()), \
             patch.object(memory.resource, "getrlimit", return_value=(limit, limit)), \
             patch.object(memory.resource, "setrlimit", side_effect=AssertionError("AS setter before observation")), \
             patch.object(memory, "inventory", side_effect=inventory), patch.object(memory, "emit"), \
             patch.object(memory, "limit_paths", side_effect=lambda _: events.append("allocations") or True), \
             patch.object(memory, "headroom_paths", side_effect=lambda *_: events.append("headroom") or True):
            memory.run_case(dict(memoryCase=case, execLimit=limit, execPID=42, referenceRegions=self.reference(), runtimeEnvironment=self.environment()))
        self.assertEqual(events, ["allocations", "headroom", "inventory"])

    def test_too_small_limit_is_rejected_even_when_allocations_match(self):
        case, records = self.evidence()
        records[0]["limitBytes"] -= memory.GIB
        records[0]["limits"] = [records[0]["limitBytes"]] * 2
        records[-1]["limits"] = records[0]["limits"]
        with self.assertRaisesRegex(ValueError, "candidate limit"):
            memory.validate_case(case, records, 42, self.reference(), self.environment())

    def test_headroom_checks_all_three_paths_and_exact_measured_sizes(self):
        for mutation in (lambda r: r["observations"].pop(),
                         lambda r: r["observations"][0].update(bytes=1024*1024),
                         lambda r: r.update(explicitPayloadTouches=1)):
            record = self.headroom(28 * memory.GIB)
            mutation(record)
            with self.assertRaises(ValueError):
                memory.validate_headroom(record, 28 * memory.GIB)

    def test_protection_worker_uses_copy_on_write_with_readonly_maximum_control(self):
        case = next(c for c in memory.case_specs() if c["name"] == "control-protect")
        rows = [dict(r, isSubmap=int(r["kind"] == "shared"),
                     protection=int(r["kind"] == "shared"), maxProtection=int(r["kind"] == "shared"),
                     shareMode=3, objectID=0, references=0) for r in self.reference()]
        page = dict(address=4096, bytes=16384, isSubmap=0, protection=1, maxProtection=1,
                    shareMode=2, objectID=1, references=1)
        native = Mock()
        native.temporary.return_value = page["address"]
        native.protect.return_value = native.deallocate.return_value = 0
        limits = [(memory.resource.RLIM_INFINITY,) * 2]
        def set_limit(_which, value):
            limits[0] = value
        snapshots = [(rows, 23 * memory.GIB), (rows + [page], 23 * memory.GIB + 16384),
                     (rows + [dict(page, protection=3, maxProtection=3)], 23 * memory.GIB + 16384)]
        with patch.object(memory.os, "uname", return_value=SimpleNamespace(version=memory.KERNEL)), \
             patch.object(memory.sys, "version_info", (3, 13, 15)), patch.object(memory.sys, "argv", ["probe"]), \
             patch.object(memory, "Native", return_value=native), patch.object(memory, "emit"), \
             patch.object(memory, "environment_observation", return_value=self.environment()), \
             patch.object(memory.resource, "getpagesize", return_value=16384), \
             patch.object(memory.resource, "getrlimit", side_effect=lambda _: limits[0]), \
             patch.object(memory.resource, "setrlimit", side_effect=set_limit), \
             patch.object(memory, "inventory", side_effect=snapshots), patch.object(memory, "limit_paths", return_value=True):
            memory.run_case(dict(memoryCase=case, referenceRegions=self.reference(), runtimeEnvironment=self.environment()))
        self.assertEqual([call.args[3:] for call in native.protect.call_args_list], [(1, 1), (0, 0x13)])
        native.deallocate.assert_called_once_with(native.task, page["address"], 16384)

    def map_records(self, rows):
        return ([dict(channel="limit", stage="post-ctypes-task", pid=42)]
                + [dict(r, channel="limit", stage="map-region", pid=42, index=i) for i, r in enumerate(rows)]
                + [dict(channel="limit", stage="map-end", pid=42, endCode=1,
                        regions=len(rows), topLevelBytes=sum(r["bytes"] for r in rows))])

    def region_evidence(self, operation="overwrite", kind="guard", code=2, removed=False, downgraded=False):
        case = next(c for c in memory.case_specs() if c["kind"] == kind and c["operation"] == operation)
        _, records = self.evidence()
        records[0]["case"] = records[-1]["case"] = case
        target = next(r for r in self.reference() if r["kind"] == kind)
        address, size = target["address"], target["bytes"] if operation == "deallocate" else 16384
        rows = [dict(address=r["address"], bytes=r["bytes"], protection=int(r["kind"] == "shared"),
                     maxProtection=int(r["kind"] == "shared"), index=i)
                for i, r in enumerate(self.reference())]
        rows.append(dict(address=300 * memory.GIB, bytes=memory.GIB, protection=3, maxProtection=3, index=22))
        after_rows = deepcopy(rows)
        if removed:
            after_rows = [r for r in after_rows if r["address"] != address]
        if downgraded:
            next(r for r in after_rows if r["address"] == address).update(protection=0, maxProtection=0)
        for i, row in enumerate(after_rows):
            row["index"] = i
        before, after = memory.coverage(rows, address, size), memory.coverage(after_rows, address, size)
        completed = records[-1]
        completed.update(before=before, after=after, code=code, errno=0, candidateSupported=not removed,
                         afterCandidateRegions=self.reference())
        return case, ([dict(stage="case-environment", pid=42, case=case, environment=self.environment()), records[0]]
                      + self.map_records(rows)
                      + [dict(stage="before-operation", pid=42, case=case, address=address, bytes=size, coverage=before),
                         dict(stage="operation-returned", pid=42, code=code, errno=0)]
                      + self.map_records(after_rows) + [records[1], completed])

    def test_region_parent_uses_full_inventory_and_reference_target(self):
        case, records = self.region_evidence()
        self.assertEqual(memory.validate_case(case, records, 42, self.reference(), self.environment()),
                         (self.reference()[0]["address"], memory.GIB))
        for mutation in (lambda r: r[-1]["after"]["regions"][0].update(maxProtection=3, protection=3),
                         lambda r: next(x for x in r if x.get("stage") == "before-operation").update(address=0),
                         lambda r: next(x for x in r if x.get("stage") == "operation-returned").update(code=0),
                         lambda r: r.pop(next(i for i, x in enumerate(r) if x.get("stage") == "map-region"))):
            changed = deepcopy(records)
            mutation(changed)
            with self.assertRaises(ValueError):
                memory.validate_case(case, changed, 42, self.reference(), self.environment())

    def test_deallocation_success_code_with_retained_guard_is_valid(self):
        for kind in ("guard", "shared"):
            for code in (0, 2):
                case, records = self.region_evidence("deallocate", kind, code=code, downgraded=True)
                target = next(r for r in self.reference() if r["kind"] == kind)
                self.assertEqual(memory.validate_case(case, records, 42, self.reference(), self.environment()),
                                 (target["address"], target["bytes"]))

    def test_deallocation_removed_mapping_contradicts_regardless_of_return_code(self):
        for code in (0, 2):
            case, records = self.region_evidence("deallocate", code=code, removed=True)
            with self.assertRaises(memory.CandidateContradiction) as failure:
                memory.validate_case(case, records, 42, self.reference(), self.environment())
            self.assertEqual(failure.exception.target, (self.reference()[0]["address"], memory.GIB))

    def test_retained_readonly_submap_is_reported_as_protection_reduced(self):
        _, records = self.region_evidence("deallocate", "shared", code=0, downgraded=True)
        self.assertEqual(memory.retention_state(records[-1]["before"], records[-1]["after"]),
                         "retained-with-reduced-protection")

    def test_forged_selected_subset_cannot_hide_full_inventory_change(self):
        case, records = self.region_evidence()
        after_start = max(i for i, r in enumerate(records) if r.get("stage") == "post-ctypes-task")
        records[after_start + 1]["maxProtection"] = 3
        with self.assertRaisesRegex(ValueError, "full inventory"):
            memory.validate_case(case, records, 42, self.reference(), self.environment())

    def test_headroom_worker_reads_size_before_each_allocation_without_setting_limits(self):
        native, events = Mock(), []
        limit, page = 28 * memory.GIB, 16384
        totals = [limit - 5 * memory.GIB - i * page for i in range(6)]
        def mapped():
            index = len([event for event in events if event[0] == "size"])
            events.append(("size", totals[index]))
            return totals[index]
        def allocate(_native, mechanism, size):
            index = len([event for event in events if event[0] == "allocation"])
            events.append(("allocation", mechanism, size))
            return index % 2 == 0
        native.mapped_bytes.side_effect = mapped
        with patch.object(memory, "allocate_once", side_effect=allocate), patch.object(memory, "emit") as emitted, \
             patch.object(memory.resource, "getpagesize", return_value=page), \
             patch.object(memory.resource, "setrlimit", side_effect=AssertionError("headroom must not set limits")):
            self.assertTrue(memory.headroom_paths(native, limit))
        self.assertEqual([event[0] for event in events], ["size", "allocation"] * 6)
        expected = [(mechanism, (limit - totals[i] - 16*1024*1024) // page * page if i % 2 == 0
                     else ((limit-totals[i]) // page + 1) * page)
                    for i, mechanism in enumerate(("malloc", "malloc", "mmap", "mmap", "mach", "mach"))]
        self.assertEqual([event[1:] for event in events if event[0] == "allocation"], expected)
        self.assertTrue(memory.validate_headroom(dict(emitted.call_args.kwargs), limit))

    def test_valid_headroom_evidence_can_show_a_contradiction(self):
        record = self.headroom(28 * memory.GIB)
        record["observations"][1]["accepted"] = True
        self.assertFalse(memory.validate_headroom(record, 28 * memory.GIB))

    def test_image_version_is_recorded_but_not_required_or_part_of_identity(self):
        version = plistlib.dumps(dict(ProductBuildVersion="25G332", ProductVersion="26.7.2"))
        with patch.object(memory.Path, "read_bytes", return_value=version), \
             patch.object(memory.os, "uname", return_value=SimpleNamespace(version="new kernel", machine="arm64")):
            missing = memory.environment_observation({})
            present = memory.environment_observation({"ImageVersion": "new image"})
        self.assertIsNone(missing["imageVersion"])
        self.assertEqual(present["imageVersion"], "new image")
        self.assertEqual(memory.environment_identity(missing), memory.environment_identity(present))
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(probe, "environment_observation", return_value=missing):
            self.assertEqual(probe.memory_environment_preflight(Path(directory), {}), memory.environment_identity(missing))
            result = json.loads((Path(directory) / "memory-environment-preflight.json").read_text())
            self.assertFalse(result["sameAsHistoricalKernelBuild"])
            self.assertIsNone(result["observed"]["imageVersion"])

    def test_worker_refuses_changed_same_run_kernel_or_build_before_native_calls(self):
        for changed in (dict(self.environment(), kernel="changed"), dict(self.environment(), osBuild="changed")):
            with patch.object(memory, "environment_observation", return_value=changed), \
                 patch.object(memory, "Native") as native:
                with self.assertRaisesRegex(ValueError, "same-run environment"):
                    memory.run_case(dict(memoryCase=memory.case_specs()[0], runtimeEnvironment=self.environment()))
                native.assert_not_called()

    def test_environment_mismatch_has_no_candidate_verdict_and_no_cases(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(probe, "environment_observation", return_value=dict(self.environment(), productVersion="27.0")):
            output = Path(directory)
            with self.assertRaisesRegex(ValueError, "precondition mismatch"):
                probe.memory_environment_preflight(output, {})
            result = json.loads((output / "memory-result.json").read_text())
            self.assertIsNone(result["candidateSupported"])
            self.assertEqual(result["classification"], "precondition-mismatch")
            self.assertEqual(result["cases"], [])

    def test_failed_interpreter_preflight_starts_no_cases(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(probe, "memory_worker", return_value=([], dict(pid=42, timedOut=False), {"message": "crash"})) as worker:
            with self.assertRaisesRegex(ValueError, "precondition"):
                probe.observe_memory(Path(directory), None, None, None, None, None, self.environment())
            self.assertEqual(worker.call_count, 1)
            result = json.loads((Path(directory) / "memory-result.json").read_text())
            self.assertIsNone(result["candidateSupported"])
            self.assertEqual(result["cases"], [])

    def test_preflight_rejects_wrong_composition_duplicate_ranges_and_python(self):
        rows = [dict(r, isSubmap=int(r["kind"] == "shared"),
                     protection=int(r["kind"] == "shared"), maxProtection=int(r["kind"] == "shared"),
                     shareMode=3, objectID=0, references=0) for r in self.reference()]
        record = dict(stage="preflight", pid=42, environment=self.environment(), pythonVersion=[3, 13, 15],
                      pageBytes=16384, regions=rows, totalBytes=22*memory.GIB)
        self.assertEqual(memory.validate_preflight([record], 42, self.environment()), self.reference())
        for mutation in (lambda r: r["regions"].pop(),
                         lambda r: r["regions"][1].update(address=r["regions"][0]["address"]),
                         lambda r: r.update(pythonVersion=[3, 14, 0]),
                         lambda r: r.update(pageBytes=4096)):
            changed = deepcopy(record)
            mutation(changed)
            with self.assertRaises(ValueError):
                memory.validate_preflight([changed], 42, self.environment())

    def test_duplicate_region_targets_cannot_satisfy_batch_coverage(self):
        cases = [dict(name=f"guard-{i}-overwrite", kind="guard", index=i, operation="overwrite") for i in range(2)]
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(probe, "memory_worker", return_value=([], dict(pid=42, timedOut=False), None)), \
             patch.object(probe, "validate_preflight", return_value=self.reference()), \
             patch.object(probe, "case_specs", return_value=cases), \
             patch.object(probe, "validate_case", return_value=(self.reference()[0]["address"], memory.GIB)):
            with self.assertRaises(ValueError):
                probe.observe_memory(Path(directory), None, None, None, None, None, self.environment())
            result = json.loads((Path(directory) / "memory-result.json").read_text())
            self.assertFalse(result["candidateSupported"])
            self.assertIn("duplicate region", result["cases"][1]["error"]["message"])

    def test_missing_receipt_or_deadline_preserves_incomplete_result(self):
        for message in ("owned memory process receipt missing", "memory diagnostic overall deadline"):
            with tempfile.TemporaryDirectory() as directory, \
                 patch.object(probe, "memory_worker", side_effect=[([], dict(pid=42, timedOut=False), None), ValueError(message)]), \
                 patch.object(probe, "validate_preflight", return_value=self.reference()):
                with self.assertRaises(ValueError):
                    probe.observe_memory(Path(directory), None, None, None, None, None, self.environment())
                result = json.loads((Path(directory) / "memory-result.json").read_text())
                self.assertEqual(result["classification"], "measurement-incomplete")
                self.assertEqual(result["error"], message)

    def test_timeout_records_case_and_stops_before_next_worker(self):
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(probe, "memory_worker", side_effect=[([], dict(pid=42, timedOut=False), None),
                         ([], dict(pid=43, timedOut=True), {"message": "timeout"})]) as worker, \
             patch.object(probe, "validate_preflight", return_value=self.reference()):
            with self.assertRaises(ValueError):
                probe.observe_memory(Path(directory), None, None, None, None, None, self.environment())
            result = json.loads((Path(directory) / "memory-result.json").read_text())
            self.assertEqual(worker.call_count, 2)
            self.assertEqual(len(result["cases"]), 1)
            self.assertEqual(result["classification"], "measurement-incomplete")
            self.assertFalse(result["candidateSupported"])

    def test_complete_distinct_region_coverage_is_required_for_success(self):
        reference = self.reference()
        def validate(case, *_):
            if case["kind"] in ("guard", "shared"):
                region = [r for r in reference if r["kind"] == case["kind"]][case["index"]]
                return region["address"], region["bytes"]
            return None
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(probe, "memory_worker", return_value=([], dict(pid=42, timedOut=False), None)) as worker, \
             patch.object(probe, "validate_preflight", return_value=reference), \
             patch.object(probe, "validate_case", side_effect=validate):
            result = probe.observe_memory(Path(directory), None, None, None, None, None, self.environment())
            self.assertTrue(result["candidateSupported"])
            self.assertEqual(len(result["cases"]), 73)
            self.assertEqual(worker.call_count, 74)

    def test_complete_contradiction_keeps_coverage_and_is_not_an_incomplete_measurement(self):
        reference = self.reference()
        def validate(case, *_):
            if case["kind"] in ("guard", "shared"):
                row = [r for r in reference if r["kind"] == case["kind"]][case["index"]]
                target = row["address"], row["bytes"]
                if case["name"] == "guard-0-deallocate":
                    raise memory.CandidateContradiction("region removed", target)
                return target
            return None
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(probe, "memory_worker", return_value=([], dict(pid=42, timedOut=False), None)), \
             patch.object(probe, "validate_preflight", return_value=reference), \
             patch.object(probe, "validate_case", side_effect=validate):
            with self.assertRaises(ValueError):
                probe.observe_memory(Path(directory), None, None, None, None, None, self.environment())
            result = json.loads((Path(directory) / "memory-result.json").read_text())
            self.assertTrue(result["observationsComplete"])
            self.assertEqual(len(result["cases"]), 73)
            self.assertEqual(result["classification"], "candidate-contradicted")
            self.assertFalse(result["candidateSupported"])

    def test_worker_parse_failure_preserves_process_receipt_and_command_error(self):
        def command(_args, output, **_kwargs):
            output.with_suffix(".stdout.log").write_text('NGV_MEMORY {"unfinished":')
            probe.save(output.with_suffix(".process.json"),
                       dict(pid=42, exitCode=1, timedOut=False, reaped=True, cleanupError=None))
            raise ValueError("child failed")
        peer = Mock(pid=123)
        peer.poll.return_value = None
        with tempfile.TemporaryDirectory() as directory, patch.object(probe, "run_command", side_effect=command), \
             patch.object(probe.time, "monotonic", return_value=1):
            observed, process, error = probe.memory_worker(Path(directory), Path("runtime"), Path("probe"),
                Path("outside"), peer, 1234, memory.case_specs()[0], self.reference(), 180, self.environment())
        self.assertEqual(observed, [])
        self.assertTrue(process["reaped"])
        self.assertEqual(error["type"], "JSONDecodeError")
        self.assertEqual(error["commandError"]["message"], "child failed")


if __name__ == "__main__":
    unittest.main()
