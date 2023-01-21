# Shared-Workflows

This repository contains reusable workflows and composite actions for other repositories.

# Caveats

* Use `if: job.status == 'failure'` instead of `if: failure()` in composite actions to read the global job status.

# Resources

https://docs.github.com/en/actions/using-workflows/reusing-workflows

https://docs.github.com/en/actions/creating-actions/creating-a-composite-action
