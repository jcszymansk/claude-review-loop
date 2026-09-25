Phase 1 complete. The __REVIEWER__ review for round __ROUND__ __REVIEW_STATUS__.

Original task:
__TASK__

Before changing any code, read the full round history in __REVIEW_DIR__.
Read every review-*.md and summary-*.md file in that directory, including
__REVIEW_DIR__/summary-0.md and __REVIEW_FILE__.

Read __REVIEW_FILE__ and address the findings:
1. Read the review carefully
2. For each item, independently decide if you agree
3. Verify each item against the codebase before changing anything: open the
   referenced file and line (or directory), and confirm the issue is still
   present by reproducing it when applicable or by inspecting the code
4. For items you AGREE with and verified: implement the fix
5. For items you DISAGREE with, that you could not verify, or that are
   already fixed: briefly note why you are skipping them under Skipped
   findings
6. Focus on critical and high severity items first
7. Write a non-empty summary to __SUMMARY_FILE__ with these Markdown sections:
   ## Fixes
   ## Skipped findings
   ## Quality gates
   Record each fix, skipped finding, and verification command with its result
   (PASS, FAIL, or NOT RUN), and note the verification you performed for each
   fix in the Fixes section

If __REVIEW_FILE__ is missing or malformed, rerun the reviewer with the Bash tool's
`run_in_background` option (the script stops the reviewer at its own time
limit), and wait for the completion notification before continuing:
```
bash __RUNNER_SCRIPT__
```

Use your own judgment. Do not blindly accept every suggestion.
