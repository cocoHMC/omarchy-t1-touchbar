# Testing and release validation

## Testing and promotion policy (owner directive, 2026-11-17)

This policy replaces older instructions to test on feature branches, run every suite after every edit, or repeat successful tests before/after promotion. It applies to Codex, Coco/dots, other agents, local hooks, and CI.

- Develop and review changes on isolated branches. Do not run test suites on feature branches, pull-request merge refs, `main`/`master`, or legacy staging branches. Read code and inspect the diff; do not start test watchers, coverage runs, broad smoke sweeps, or repeated build/lint/typecheck loops as a substitute.
- Integrate the intended batch into `beta` first. A validation owner or CI run claims the exact clean beta commit, selects the smallest set of checks that covers the changed behavior and material integration risks, and runs that set once. Other agents reuse that result instead of launching parallel validation.
- Keep existing tests. Add or update regression coverage when it protects changed behavior, an important defect, security/privacy, permissions, money, migrations/data integrity, or a critical user flow. Do not create tests merely to mirror implementation or test low-impact copy/style changes.
- Reserve broad suites for changes with a documented cross-cutting risk. Documentation-only changes normally need a diff review, not application tests. A skipped or unavailable check is not a passing check.
- Record the beta commit SHA, checked scope, commands/jobs, results and any justified skips in the existing CI/release receipt. Reuse successful evidence for that exact candidate. Retry only failed/affected checks after a relevant fix or an identified infrastructure failure; record the reason. New relevant source, dependency or configuration changes need a new beta validation record.
- Promote to production `main` (or the repository's existing production `master`) only after the applicable beta checks succeed and the release source matches the validated candidate. Prefer the validated artifacts. A merge commit may have a different SHA only when its tree matches the validated beta tree; a changed release tree goes back through beta. Do not run the same suites again on main.
- Keep approval, authentication, secret scanning, access control, backup, migration, signing and release safeguards. Required packaging/compilation is allowed to produce an artifact; do not hide duplicate tests inside builds, hooks, or deployment scripts. Production health monitoring is distinct from rerunning a test suite.
- Existing security/release restrictions still apply. This policy does not authorize unrelated merges, production deployments, store submissions, or changes to branch protections. If an existing required check conflicts with beta-only validation, report the concrete configuration dependency instead of faking a success or bypassing it.

