# #547 implementation design

Base: e59f08d377712b58f3694383b11302fed6f5860a, clean codex/issue-547. No second docs merge.

## Compatibility and ownership

Keep every existing public V1 stored layout, all old runtime libraries and project pins. Introduce separate versioned 3.4 library IDs, exact source sections and Unicode-offset units through the existing closed-schema knowledge loader. Do not mutate V1 resource IDs to mean 3.4. Source provenance remains the supplied archive SHA256, not a claimed Git commit. Resource reads expose exact byte digests and source locators; plan reads use one technique, whole runbook/recipe and precise shared 12h paragraphs. Both backends already invoke get_production_knowledge through the host ToolExecutor; extend that consumer rather than create another backend.

A technique decision belongs to Production Design after approved analysis, alongside the existing resolved production style. Use a new Codable sidecar type (not a V1 layout field), canonical host writer via write_production_design, exact-byte lineage over project/brief/design, independent Production Design gate and downstream cumulative lineage/compiler token binding. Persist source version, A/B/C, choice rationale, decision versus ASSUMED, explicit assumption scope and approval lineage. No automatic default, no change on read. Require explicit Production Design rewind for a changed decision. Optional new artifact has no mandatory old-project migration. Full activation still requires a supported current-pack contract; old exact pins must retain their resource meaning.

Technique compiler is a new typed path over the unchanged VideoPromptIRV1 with new economy/technique context. H3 retains its official outer container; A/B/C govern only its description. Approved canon controls survive; model-owned axes require reasoned evidence rather than classifying all populated fields as deliberate. Slate uses actual final bytes; semantic measures stay unmeasured absent observed evidence. No fabricated PASS. Repair checks actual bytes, protected exact lines and non-growing word count.

Iteration policy is invoked by existing take assessment; four reviewed rolls, >=3 same-axis failures wins over one accepted outlier. Reject overfull groups instead of silently treating arbitrary sample size as one iteration. Derived rescue requires separate operation authorization and new take lineage; the existing generation authorization is not reused. No paid execution.

## Concrete locked-contract conflict (dependent economy change withheld)

The locked docs/PRODUCTION_PROFILES.md lines 67–79 require every planned video's approved camera movement, blocking anchors, continuity locks, match-action and rescue directives in actual prompt bytes; independent Frames/Render gates enforce those exact directives. 3.4 default model ownership would allow omitting camera/mechanics/lighting despite a populated old plan. Treating all old mandatory fields as deliberate look would fabricate the required reason. Proposal: add an explicitly opted-in, versioned production intent contract with sparse axis ownership and reasoned controls, preserving legacy plan/gate behavior. That changes the locked projection contract and overlaps #559; approval is NOT present. Do not alter those compulsory projections or gates under #547. Independent corpus retrieval, trace receipts, source disposition and policy corrections can proceed.

## Evidence

Prepare Actions-only tests over actual bundled loader resources and host tool reads for entry/unit/runbook/blueprint addressing and technique isolation; four-roll counterexamples and exact-byte repair fixtures. Do not run tests, compilers, app, workers, probes, servers or CI. Static diff/schema inspection only. Completion must distinguish authored fixtures from executed evidence and leave blocked acceptance explicit.

## Refinement: independent technique work proceeds

The sparse ownership conflict blocks omitting locked directives, not technique persistence or shape. Add the optional Production Design sidecar, include it in the current Musicvideo pack's exact-byte phase lineage and host compiler-input binding, and require an explicitly capable pack before creating it. Absence keeps legacy behavior byte-for-byte; no old pin is rewritten. A/B/C shape consumes the same existing mandatory approved directives until the sparse contract is separately settled. It must not classify them as a new deliberate-look decision. New pack binary references need a new additive Engine contract and pack version; coordinate the overlapping #537 batch number rather than assuming its symbols exist here. The host minimum stays unchanged.
