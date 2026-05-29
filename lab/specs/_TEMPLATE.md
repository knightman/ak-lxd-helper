# NNN — <title>

- **Status:** ⚪ planned | 🟡 in progress | 🟢 done
- **Skills:** `<skill-a>`, `<skill-b>`
- **Instance(s):** `lab-NNN-<slug>`

## Goal

One or two sentences: what this experiment proves or builds, and why.

## Inputs / parameters

| Name | Default | Notes |
|------|---------|-------|
| release | 24.04 | Ubuntu cloud image |
| cpu / memory / disk | 2 / 4GiB / 20GiB | |

## Preconditions

- Dashboard server running; `DOCKER-USER` networking fix applied on host.
- Any upstream instances/specs this depends on.

## Steps

1. `lxd-vm-create` … (which skill, with what params)
2. …

## Acceptance criteria

- [ ] criterion 1 (a concrete, checkable assertion)
- [ ] …

## Verification

```bash
# exact commands that prove the acceptance criteria
```

## Teardown

```bash
lab/scripts/lab.sh teardown lab-NNN-<slug>
```

## Results

_(filled after a run: date, captured version strings/output, pass/fail, notes)_
