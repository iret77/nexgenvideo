import unittest

from app_termination_acceptance import verify


class TerminationEvidenceTests(unittest.TestCase):
    source = "a" * 40

    def events(self, names):
        return [dict(event=name, pid=123, sourceSHA=self.source, uptime=float(index * 4))
                for index, name in enumerate(names)]

    def completed(self):
        return self.events(["boot", "request-accepted", "should-terminate", "reply-later", "cleanup-start", "cleanup-resumed",
                            "cleanup-done", "will-terminate", "process-exit"])

    def test_requires_normal_exit_after_completed_async_cleanup(self):
        events = self.completed()
        verify("task", events, 123, self.source, 0)
        with self.assertRaisesRegex(AssertionError, "exit normally"):
            verify("task", events, 123, self.source, -15)
        for missing in ("cleanup-resumed", "cleanup-done", "process-exit"):
            with self.subTest(missing=missing), self.assertRaisesRegex(AssertionError, "proof"):
                verify("task", [event for event in events if event["event"] != missing], 123, self.source, 0)

    def test_exit_before_cleanup_is_rejected(self):
        events = self.completed()
        events[-1], events[-3] = events[-3], events[-1]
        with self.assertRaisesRegex(AssertionError, "order"):
            verify("task", events, 123, self.source, 0)

    def test_cancel_requires_survival_and_refuses_a_committed_restart(self):
        events = self.events(["boot", "request-accepted", "should-terminate", "reply-later", "cancelled", "alive-after-cancel",
                              "should-terminate", "reply-later", "cleanup-start", "cleanup-resumed", "cleanup-done",
                              "will-terminate", "process-exit"])
        verify("relaunch-cancel", events, 123, self.source, 0)
        with self.assertRaisesRegex(AssertionError, "unapproved restart"):
            verify("relaunch-cancel", events + self.events(["relaunch-commit"]), 123, self.source, 0)
        events[5]["uptime"] = events[4]["uptime"] + 0.1
        with self.assertRaisesRegex(AssertionError, "former forced-exit"):
            verify("cancel", events, 123, self.source, 0)

    def test_control_requires_a_real_wait_before_cleanup(self):
        events = self.events(["boot", "should-terminate"])
        verify("raw-control", events, 123, self.source, None, True)
        with self.assertRaisesRegex(AssertionError, "did not reproduce"):
            verify("raw-control", events, 123, self.source, 0)
        with self.assertRaisesRegex(AssertionError, "entered async cleanup"):
            verify("raw-control", events + self.events(["cleanup-start"]), 123, self.source, None, True)

    def test_foreign_source_or_process_is_rejected(self):
        events = self.completed()
        with self.assertRaisesRegex(AssertionError, "foreign-source"):
            verify("task", events, 123, "b" * 40, 0)
        foreign = dict(events[-1], pid=456)
        with self.assertRaisesRegex(AssertionError, "second application"):
            verify("task", events + [foreign], 123, self.source, 0)

    def test_duplicate_quit_must_be_coalesced_and_native_reentry_must_return(self):
        events = self.events(["boot", "request-accepted", "should-terminate", "reply-later", "duplicate-rejected", "duplicate-rejected",
                              "cleanup-start", "native-duplicate", "should-terminate",
                              "reply-cancel", "native-duplicate-returned", "cleanup-resumed", "cleanup-done",
                              "will-terminate", "process-exit"])
        verify("duplicate", events, 123, self.source, 0)
        with self.assertRaisesRegex(AssertionError, "re-entry did not return"):
            verify("duplicate", [event for event in events if event["event"] != "native-duplicate-returned"],
                   123, self.source, 0)
        events[4]["event"] = "duplicate-accepted"
        with self.assertRaisesRegex(AssertionError, "accepted"):
            verify("duplicate", events, 123, self.source, 0)

    def test_relaunch_requires_cleanup_commit_normal_exit_and_one_exact_child(self):
        events = self.events(["boot", "should-terminate", "reply-later", "cleanup-start", "cleanup-resumed",
                              "cleanup-done", "will-terminate", "relaunch-commit", "reopener-started", "process-exit"])
        events[8]["childPID"] = 456
        child = self.events(["boot", "reopened", "should-terminate", "reply-later", "cleanup-start",
                             "cleanup-resumed", "cleanup-done", "will-terminate", "process-exit"])
        for event in child:
            event.update(pid=456, uptime=event["uptime"] + 50)
        events += child
        verify("relaunch", events, 123, self.source, 0)
        import copy
        mutations = []
        value = copy.deepcopy(events); value[6], value[7] = value[7], value[6]; mutations.append(value)
        value = copy.deepcopy(events); value[8], value[9] = value[9], value[8]; mutations.append(value)
        value = copy.deepcopy(events); value[11]["uptime"] = 0; mutations.append(value)
        value = copy.deepcopy(events); value[8]["childPID"] = 123; mutations.append(value)
        value = copy.deepcopy(events); value.append(dict(value[-1], pid=789)); mutations.append(value)
        value = copy.deepcopy(events); value.append(dict(value[11])); mutations.append(value)
        mutations.append(copy.deepcopy(events[:10]))
        value = copy.deepcopy(events); value.append(dict(value[8], event="reopener-failed")); mutations.append(value)
        for index, value in enumerate(mutations):
            with self.subTest(index=index), self.assertRaises(AssertionError):
                verify("relaunch", value, 123, self.source, 0)


if __name__ == "__main__":
    unittest.main()
