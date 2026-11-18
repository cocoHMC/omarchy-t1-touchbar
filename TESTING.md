# Build, prepare beta, release

Owner workflow, 2026-11-18. This is the repository's source of truth for
integration, validation timing and release approval. It replaces older
instructions that require feature-branch tests, mandatory worktrees, validation
on every beta push, or another approval for an already authorized step.
Project-specific data, access, signing and recovery safeguards still apply.

## 1. Build — the default

- Implement the requested work and review the source and diff. Do not author or
  run tests, validation builds, lint/typecheck sweeps, coverage or test watchers
  during feature work. Preserve existing tests; add useful regression coverage
  during release preparation. Reading code and inspecting Git state are allowed.
- `beta` is the shared home for completed development. Use it directly when
  there is one writer and the checkout is safe. Temporary branches/worktrees are
  optional agent bookkeeping for concurrent work, never the user's job.
- Finish by integrating the task's completed work into current remote `beta`.
  Resolve integration conflicts, preserve other work, and verify the remote
  commit contains the intended changes. The build request authorizes this
  integration; do not stop at an unmerged PR or ask again. If GitHub requires a
  PR, use it and complete the authorized merge.
- Serialize shared-branch writes and refresh before pushing. Never force-push
  shared history. Do not sweep unrelated or unfinished work into beta.
- After verified integration, remove the task's remote/local temporary branch
  and worktree automatically. First verify its changes are in beta and it has
  no active owner, uncommitted changes or unique files. Preserve and integrate
  recoverable work before cleanup; a missing preservation check is not license
  to delete it. Report an actual unresolved item without making the user manage
  routine Git bookkeeping.
- A beta push or merge does not authorize testing, deployment, TestFlight,
  Play distribution or store submission. Keep building until told otherwise.

## 2. "Prepare beta" — validate and polish

- An explicit request to prepare, test or make beta production-ready starts
  this phase. Claim one integrated beta candidate and coordinate with other
  writers so new work cannot silently enter the release being validated.
- Review the complete accumulated batch and its user flows. Fix broken behavior,
  integration issues, confusing UI and material accessibility or quality defects.
  Make these fixes on beta; temporary fix branches must land there first.
- Select meaningful checks for the batch and its risks, then run them on beta.
  Include relevant authentication/permissions, money, migrations/data integrity
  and critical native/web flows. Use broad suites when the batch warrants them.
  Use approved self-hosted runners and existing release tooling.
- Share one validation result per candidate. Reuse successful unaffected checks;
  rerun failed or affected checks after fixes. Do not restart every suite after
  each edit or rerun the same suite on main. Keep a compact record of candidate
  commit, scope, results and remaining blockers in the existing receipt.
- Existing unrelated warnings are reported separately, not an automatic demand
  to repair the entire repository. Actual build failures, relevant regressions,
  security/data risks and missing required evidence remain real blockers.
  Never relabel a failed/skipped check as passing.
- Preparing beta does not by itself authorize a production release.

## 3. "Push to production" — promote and deliver

- Honor approval already given, including "prepare beta and then push to
  production" in one request. Finish preparation and proceed without asking
  again. Do not invent a standing release window.
- Promote only the prepared candidate to production `main` (or an existing
  `master` until its deployment wiring is deliberately migrated). Verify source
  equivalence and deploy the matching artifact through the established route.
  If beta changed materially, prepare the changed candidate before promotion.
- Deliver the approved web/API/database release, with relevant migration,
  recovery and production-health checks. Keep compatibility with native
  versions people still have installed. Never reset customer data.
- Where native apps exist, build/sign/package the approved main source for
  **internal TestFlight** and **Google Play internal testing**. Packaging needed
  for delivery is allowed; do not hide duplicate test suites inside packaging.
  A source merge alone is not a successful deployment or upload.
- Report actual deployed versions and internal build status. If a required
  credential, runner, migration prerequisite or store capability is unavailable,
  finish independent work and name the specific remaining dependency.

## 4. "Submit to the store" — separate approval

After internal testing, submit the identified app/build to App Store review or
Google Play production only when the owner requests it. Main pushes and
internal distribution must not automatically submit or publish public releases.
Respect explicitly private apps. Approval persists for the requested action;
do not ask repeatedly or infer public-release approval from a build request.
