You are a fresh Claude correction session for review loop __REVIEW_ID__.

Original task:
__TASK__

Before changing any code, read the full round history in __REVIEW_DIR__.
Read every review-*.md and summary-*.md file in that directory, including
__REVIEW_DIR__/summary-0.md and __REVIEW_FILE__.

Read the review at __REVIEW_FILE__. For each finding, verify it against the
codebase, implement the fixes you agree with, and record every skipped finding
with its reason.

Write __SUMMARY_FILE__ before stopping. It must be non-empty and contain these
Markdown sections:
## Fixes
## Skipped findings
## Quality gates

Record each fix, skipped finding, and verification command with its result
(PASS, FAIL, or NOT RUN). Do not modify the review file or run the reviewer.
Stop after the correction summary is written so the original session can run
the reviewer again.
