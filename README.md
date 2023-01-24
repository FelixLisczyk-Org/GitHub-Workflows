# Shared-Workflows

This repository contains reusable workflows and composite actions for other repositories.

# Caveats

* Use `if: job.status == 'failure'` instead of `if: failure()` in composite actions to read the global job status.

# Debug

Print GitHub context variables:

```
- name: Dump GitHub context
  run: echo '${{ toJSON(github) }}'
- name: Dump job context
  run: echo '${{ toJSON(job) }}'
- name: Dump steps context
  run: echo '${{ toJSON(steps) }}'
- name: Dump runner context
  run: echo '${{ toJSON(runner) }}'
```

# Resources

https://docs.github.com/en/actions/using-workflows/reusing-workflows

https://docs.github.com/en/actions/creating-actions/creating-a-composite-action

https://docs.github.com/en/actions/learn-github-actions/contexts

https://docs.github.com/en/actions/learn-github-actions/expressions