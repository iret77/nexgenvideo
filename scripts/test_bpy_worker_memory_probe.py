from copy import deepcopy
import ctypes
import unittest
from unittest.mock import Mock, patch

import bpy_worker_memory_probe as memory
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

    def evidence(self, kind="direct"):
        case = next(c for c in memory.case_specs() if c["kind"] == kind)
        limit = 420 * memory.GIB
        records = [dict(stage="candidate-limit", pid=42, case=case, limitBytes=limit,
                        limits=[limit, limit], totalBytes=415 * memory.GIB,
                        candidateExemptBytes=414 * memory.GIB, afterExec=False)]
        paths = dict(stage="allocation-paths", pid=42, outcomes={label + "-" + mechanism: label == "positive"
                     for label in ("positive", "over-budget") for mechanism in ("malloc", "mmap", "mach")})
        records.append(paths)
        if kind.startswith("exec-"):
            records += [dict(stage="before-exec", pid=42), dict(records[0], afterExec=True), deepcopy(paths)]
        records.append(dict(stage="complete", pid=42, case=case, candidateSupported=True,
                            afterExec=kind.startswith("exec-"), limits=[limit, limit], runtimeAcceptance=False))
        return case, records

    def test_direct_and_both_exec_variants_require_positive_and_negative_observations(self):
        for kind in ("direct", "exec-isolated", "exec-site"):
            case, records = self.evidence(kind)
            memory.validate_case(case, records, 42)

    def test_wrong_pid_duplicate_or_unproved_completion_is_rejected(self):
        case, baseline = self.evidence()
        for change in (lambda r: r[0].update(pid=43), lambda r: r.append(deepcopy(r[-1])),
                       lambda r: r[-1].update(candidateSupported=False),
                       lambda r: r[-1].update(runtimeAcceptance=True), lambda r: r.pop(),
                       lambda r: r[-1].update(limits=[1, 1])):
            records = deepcopy(baseline)
            change(records)
            with self.assertRaises(ValueError):
                memory.validate_case(case, records, 42)

    def test_reclaimed_baseline_cannot_enlarge_reported_usable_budget(self):
        case, records = self.evidence("exec-site")
        records[3]["candidateExemptBytes"] -= memory.GIB
        with self.assertRaises(ValueError):
            memory.validate_case(case, records, 42)

    def test_missing_post_exec_observation_cannot_pass(self):
        case, records = self.evidence("exec-isolated")
        records.pop(3)
        with self.assertRaises(ValueError):
            memory.validate_case(case, records, 42)

    def test_any_accepted_large_allocation_or_failed_positive_control_rejects_candidate(self):
        for mechanism in ("malloc", "mmap", "mach"):
            for label in ("positive", "over-budget"):
                case, records = self.evidence()
                key = label + "-" + mechanism
                records[1]["outcomes"][key] = not records[1]["outcomes"][key]
                with self.assertRaises(ValueError):
                    memory.validate_case(case, records, 42)

    def test_mutable_and_object_backed_regions_are_not_exempt(self):
        guard = dict(address=0, bytes=16384, isSubmap=0, protection=0, maxProtection=0,
                     shareMode=3, objectID=0, references=0)
        self.assertEqual(memory.selected_regions([guard], "guard"), [guard])
        for field, value in (("maxProtection", 2), ("protection", 1), ("objectID", 1),
                             ("references", 1), ("isSubmap", 1), ("shareMode", 2)):
            self.assertEqual(memory.selected_regions([dict(guard, **{field: value})], "guard"), [])
        self.assertEqual(memory.selected_regions([dict(guard, isSubmap=1, protection=1, maxProtection=3)], "shared"), [])

    def test_split_mapping_coverage_counts_holes_and_writable_pages(self):
        rows = [dict(address=100, bytes=20, maxProtection=0), dict(address=130, bytes=20, maxProtection=3)]
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


if __name__ == "__main__":
    unittest.main()
