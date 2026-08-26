Phase 1 complete. The __REVIEWER__ review for round __ROUND__ __REVIEW_STATUS__.

Before changing any code, read the full round history in __REVIEW_DIR__.
Read every review-*.md and summary-*.md file in that directory, including
__REVIEW_DIR__/summary-0.md and __REVIEW_FILE__.

Read __REVIEW_FILE__ and address the findings:
1. Read the review carefully
2. For each item, independently decide if you agree
3. For items you AGREE with: implement the fix
4. For items you DISAGREE with: briefly note why you are skipping them
5. Focus on critical and high severity items first
6. Write a non-empty summary to __SUMMARY_FILE__ with these Markdown sections:
   ## Fixes
   ## Skipped findings
   ## Quality gates
   Record each fix, skipped finding, and verification command with its result
   (PASS, FAIL, or NOT RUN)

If __REVIEW_FILE__ is missing or malformed, rerun the reviewer with a 600000ms timeout:
```
bash __RUNNER_SCRIPT__
```

Use your own judgment. Do not blindly accept every suggestion.