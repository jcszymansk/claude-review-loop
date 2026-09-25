The __REVIEWER__ review has not been completed yet. Run the review script with the Bash tool's `run_in_background` option, so that no tool timeout cuts the review off; the script stops the reviewer at its own time limit:

```
bash __RUNNER_SCRIPT__
```

Wait for the background command's completion notification before doing anything else, and do not stop while it is still running. Then read __REVIEW_FILE__ and address the findings.
