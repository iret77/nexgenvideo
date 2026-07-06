# Goldens — frozen oracle fixtures

These JSON files are **frozen fixtures**, checked in as the source of truth for the
`NexGenEngine` parity tests. They were generated from the original Python engine
oracle (`engine/nexgen_engine/read.py` and friends) at the last commit before that
tree was removed in **M9** (issue #119).

They are no longer regenerated — the Python engine is gone, and `scripts/regen-goldens.sh`
was deleted with it. If you need to see how a golden was produced, the engine tree is
available in git history (the last commit carrying it: `a1bad23`; removed in the M9
rip-out). Do not attempt to re-derive them from the Swift engine — the Swift engine is
tested *against* these fixtures, so regenerating from it would make the test tautological.

To intentionally change a golden (a deliberate behavior change in the Swift engine),
edit the JSON by hand in the same PR that changes the behavior, and explain why in the
commit message.
