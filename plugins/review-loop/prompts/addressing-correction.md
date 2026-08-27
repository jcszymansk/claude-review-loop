Phase 1 complete. The __REVIEWER__ review for round __ROUND__ __REVIEW_STATUS__. A fresh interactive Claude correction session __CORRECTION_STATUS__.

Before changing any code, read the full round history in __REVIEW_DIR__.
Read every review-*.md and summary-*.md file in that directory, including
__REVIEW_DIR__/summary-0.md and __REVIEW_FILE__.

Read __REVIEW_FILE__. Verify each finding against the codebase before applying
any change: open the referenced file and line (or directory), and confirm the
issue is still present by reproducing it when applicable or by inspecting the
code. Fix only findings you verified; record findings you could not verify,
that are already fixed, or that you reject under Skipped findings with the
reason. Then write __SUMMARY_FILE__ with these Markdown sections before
running the reviewer:
## Fixes
## Skipped findings
## Quality gates
Record each fix, skipped finding, and verification command with its result
(PASS, FAIL, or NOT RUN).

```
bash __RUNNER_SCRIPT__
```