# Mini heavy-command queue

Decision: [sumelabs/sume#7315](https://github.com/sumelabs/sume/issues/7315#issuecomment-5653014379).
This cstack slice supplies the queue and runner budget contract. **Keep many
coding authors.** Only heavy test/build commands enter this queue. There is no
author/session admission limit, and no lock around `sume-bg-launch`.

## Install just the gate on a busy Mini

From an isolated, retained cstack clone:

```bash
./install.sh --test-gate-only --test-gate-profile mini16
command -v cstack-test-gate
cstack-test-gate status
```

This runs offline synthetic subprocess tests, configures the host, and links
`~/.local/bin/cstack-test-gate` directly to that checkout's
`sume-desk/bin/cstack-test-gate.py`. It does not retarget `~/.cstack/src`, live
skills, worker-launcher links, or sume-com rules. Keep the installed checkout;
do not delete it after landing. A normal `./install.sh` also installs/tests
the gate, without changing a previously configured profile unless requested.
Requires Python 3.9+ on macOS or Linux; no third-party Python modules or Linux
`flock` executable are required.

## Commands and profiles

```bash
cstack-test-gate test -- pnpm exec vitest run path/to/suite.test.ts
cstack-test-gate build -- pnpm --filter @sume-com/web build
cstack-test-gate status
# Host configuration only, while there are no queued/running/orphan tickets:
cstack-test-gate configure mini16
# Future 64 GiB machine:
cstack-test-gate configure host64
```

| Profile | Total heavy commands | Test ceiling | Build ceiling | Packages per command | Vitest budget per package |
| --- | ---: | ---: | ---: | ---: | ---: |
| `mini16` (default) | 1 | 1 | 1 | 1 | 2 |
| `host64` | 2 | 2 | 1 | 1 | min(4, CPU count) |

Ceilings intersect: **16 GiB = test XOR build**. 64 GiB allows two tests or
one test plus one build, never two builds. Values are conservative initial
limits, not a RAM guarantee. One Next build still has internal parallelism
and can exceed remaining memory. No timeout bump or test-default change is
part of this slice.

State always lives in `~/.cstack/state/test-gate/`, shared across clones on
this host/account. `CSTACK_STATE` and cwd do not redirect it. This is one
host-wide authority for the existing single worker account; multiple OS users
would need a shared authority. Do not sync this directory or use a laptop
replica for admission. `profile.json` is the host enrollment marker.

Calling the binary explicitly always queues, even with `SUME_TEST_GATE=0`.
`GITHUB_ACTIONS=true` is the sole automatic bypass: execute the original argv
and environment before touching queue state. `CI=1` alone does not bypass.
An inherited `SUME_TEST_GATE_PROFILE` must match host configuration; a caller
cannot independently increase capacity.

## Runner budget contract and remaining sume-com work

Each admitted command inherits:

```text
SUME_TEST_GATE=1
SUME_TEST_GATE_PROFILE=mini16|host64
SUME_TEST_GATE_PACKAGE_CONCURRENCY=1
SUME_TEST_GATE_MAX_WORKERS=2|4 (bounded by CPU count)
SUME_TEST_GATE_LEASE=<internal nonce>
npm_config_workspace_concurrency=1
VITEST_MAX_WORKERS=2|4
```

The binary adapts **direct** pnpm invocations with
`--workspace-concurrency=1`, direct Turbo with `--concurrency=1`, and direct
Vitest (including `pnpm exec vitest`) with `--maxWorkers=<budget>`. Explicit
smaller integer Vitest caps are retained. Parallel pnpm/Turbo mode is rejected
because it bypasses the package limit. The direct Vitest adapter selects run
mode; this gate is for finite preflights, not long-lived watch processes.

**An environment budget is not a universal enforcement mechanism.** Explicit
Vitest configs can override environment defaults; a shell script can invoke
Turbo or pnpm with its own options. Root `pnpm test` is such a composite
script. This slice does not rewrite or instrument sume-com, intercept arbitrary
shell commands, or turn the gate into an OS resource sandbox. Use explicit
supported commands or budget-aware wrappers. Do not claim automatic coverage
of ungated commands or older clones.

The follow-up thin sume-com wrappers must:

- Enroll both changed-script entry points and root/package test/build commands
  when the host marker exists or `SUME_TEST_GATE=1`, while preserving the exact
  GitHub Actions path.
- Bound all internal package branches to one, including full fallbacks and
  Turbo's root path; retain build dependency order and changed-file selection.
- Apply `min(existing package cap, SUME_TEST_GATE_MAX_WORKERS)` in local
  Vitest config/runner code, including root tests. Do not raise a smaller
  package-specific cap or change API CI's 30s/eight-worker defaults.
- Pass the lease/profile/budgets through Turbo's explicit environment allowlist.
- Assert `cstack-test-gate check test` (or `check build`) at direct runner
  boundaries, including Next's production-build phase only. Missing/stale
  leases fail with a wrapper hint before heavy execution. These are misuse
  errors; a correctly wrapped busy command waits.

The gate validates lease nonce, live supervisor identity, command class, and
ancestry in the admitted guardian tree. A nested wrapper executes under the
same lease without another ticket. A test lease cannot upgrade to a build;
reserve build at the outer boundary for a build that includes tests. Descendant
work must remain serial/budgeted; sharing a nonce is not permission to spawn
parallel heavy siblings. This is cooperative enforcement for trusted workers,
not protection against deliberate alternate configs or detached process trees.

## Waiting and validation

Tickets are monotonic and admitted in strict FIFO order. Total and class
capacity are reserved together under a short `fcntl.flock` metadata mutex.
The mutex is not held while executing or sleeping. A blocked build at the
head may leave capacity idle; newer tests cannot starve it by overtaking.

The caller blocks cheaply and logs ticket, class, position, elapsed wait,
and active ticket IDs immediately and every 30 seconds. Normal subprocess
stdout/stderr flows to the caller's worker log. Use the harness's background
shell support to continue independent work; never treat queue waiting as green.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SUME_TEST_GATE_WAIT_SECONDS` | `0` | Unlimited wait; an explicit deadline cancels with 124, never bypasses. |
| `SUME_TEST_GATE_LOG_SECONDS` | `30` | Positive, finite progress interval. |

SIGINT/TERM cancel queued tickets. Child exit status is preserved (signals as
128 + signal); misuse/stale validation returns 125. Fingerprints record HEAD,
base-SHA environment, tracked differences and non-ignored untracked contents.
Source changes while queued prevent execution; changes during execution make
the result stale/nonzero. Build outputs should be ignored by the repository.
This is endpoint validation, not an immutable checkout snapshot: callers must
not edit the same checkout during a gate. Use another author clone.

## Failure recovery

Atomic state records carry boot identity, PID/start identity, nonce, ticket,
class, checkout fingerprint, and the admitted child group. A permanent mutex
inode guards updates. Do not delete mutex/queue files to get past contention.

A guardian starts in its own process group but waits on a pipe. The supervisor
persists the reservation/group **before** sending GO. Supervisor death before
GO closes the pipe without starting heavy work. After GO, the guardian watches
its parent and cleans up its own group when the supervisor disappears. TERM
is forwarded to descendants; non-responsive members receive KILL after three
seconds. The guardian waits for the group to drain. Normal completion also
cleans up background children before releasing capacity.

Dead waiters are removed by identity checks, not ticket age. Running/orphan
groups retain capacity while alive, even when their supervisor is dead. Unknown
states are quarantined rather than granting speculative capacity. Reboot
invalidates old-boot records. Status omits lease secrets and environment values.
If both supervisor and guardian die while payloads remain, inspect the recorded
group, terminate that specific workload, then run status again to reconcile.
Never kill unrelated groups or force-delete a live reservation. Processes that
deliberately create new sessions escape this cooperative process-group model.

Laptop attach loss does not cancel a detached Mini worker or its gate. An
explicit remote worker kill reaches its gate supervisor; the separately grouped
guardian detects parent death even if TERM cleanup was interrupted by KILL.
No launcher-wide lock or coding-worker count change is needed. Eligibility
must not depend on `CSTACK_WORKER_HOST`, which the remote runner resets to local.

## Synthetic validation

```bash
python3 sume-desk/bin/cstack-test-gate.test.py
```

Tests run only tiny Python/dummy executables in temporary directories. The
hidden `--test-state-dir` option requires `CSTACK_TEST_GATE_TESTING=1` and a
system-temporary path; normal CLI use has no state-directory override. Tests
cover FIFO, both profiles, nested validation, stolen leases, termination,
supervisor death, deadlines, exact Actions bypass, budget arguments, profile
conflicts and stale source. No monorepo gate/build is part of installation.

Before the sume-com follow-up activates automatic coverage, drain existing
ungated heavy commands while keeping authors running. Then collect queue wait
separately from execution time, process-tree peak memory, memory pressure/swap,
and failure rates from ordinary authorized gates before increasing capacity.
