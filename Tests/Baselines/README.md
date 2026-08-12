# Swift Testing issue baseline

`stage-b-known-issues.txt` freezes the 27 complete Swift Testing issue records
emitted by the pre-Stage-C broad suite. Each line is a base64-encoded record so
embedded Swift Testing continuation lines remain part of its single sortable
record. Its order is `LC_ALL=C` byte sort order; a repeated record is
deliberately retained because record multiplicity is part of the issue count.

`scripts/verify-swift-testing-baseline.sh FULL_SUITE_LOG BASELINE_FILE` starts
a record at each Swift Testing line beginning `✘ Test` and containing `recorded
an issue`, then retains all continuation lines through the next Swift Testing
progress or result line. For each record it replaces only the decimal line and
column in the first Swift source location
` at filename.swift:line:column:` with ` at filename.swift:<line>:<column>:`.
The source filename and all message bytes are retained. The complete records
are base64 encoded, sorted, and compared byte-for-byte to the checked-in
baseline.

Therefore source line/column movement is accepted, while any record message,
test name or arguments, Swift filename, addition, removal, or multiplicity
change fails verification. The verifier intentionally does not regenerate the
baseline; Stage C must always be checked against this pre-Stage-C artifact.

`stage-d-known-issues.txt` is the explicit Stage D amendment; it does not
replace or rewrite the immutable Stage B artifact. Twenty-two Stage B records
were removed only after the current native sparse route independently passed
the Professional producer, raw-artifact, complete-root, validator, and
Deposition evidence gates, and after the corresponding frozen-hash-only tests
were retired. The amendment retains exactly the five still-open corrective
program observations for graphite width, charcoal visibility/alpha, and
chisel turn protrusion. The chisel record reflects the current independently
measured support-bound result; its `<= 4 px` requirement remains unchanged.

Task 18 adds `deposition-composite` and its paired negative control to the
native deposition matrix. The project-owned fixture is the maximum supported
two-component brush: distinct dry tips, spacing, dynamics, alpha/color, and a
shared grain resource. Its positive scene must satisfy the ordered-component
contract; the paired scene intentionally negates only that expectation.
