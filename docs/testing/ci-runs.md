# CI for this repo

## Automatic, on every PR

Opening or updating a pull request against `delphix/appliance-build` triggers the
**`jenkinsci/appliance-build-orchestrator`** GitHub check automatically — nothing needs to be
started by hand. It builds an appliance image (`internal-dev`, `internal-qa`,
`external-standard`, on AWS) and runs `dx-integration-tests` against it, then reports its result
back as that check.

For the exact trigger conditions and parameters, see `devops-gate`'s own
`jenkins/jobs/github_appliance_build_orchestrator_prepush.groovy` (the webhook registration) and
`jenkins/jobs/pipelines/github_appliance_build_orchestrator_prepush.groovy`/
`appliance_build_orchestrator.groovy` (what the triggered pipeline does) — that source is the
authority on this; this file doesn't try to keep its own copy of it current.

## Manual, broader runs

For a custom combination of variants/platforms, or to build together with in-flight changes in
other repos, before a PR exists (or independent of one):

- **`git ab-pre-push`** (a `git-utils` command) — `appliance-build` is a valid *primary* repo for
  it. See the
  [`using-ab-pre-push` skill](https://github.com/delphix/platform-team-claude-plugins/blob/main/plugins/git-utils/skills/using-ab-pre-push/SKILL.md)
  for the flag reference, defaults, and known gotchas — not duplicated here.
- **`git hotfix-build HOTFIX`** (also `git-utils`) — builds a hotfix image on the self-service
  Jenkins from `appliance-build`. See the
  [hotfix plugin](https://github.com/delphix/platform-team-claude-plugins/tree/main/plugins/hotfix)
  for how that works.

## Pass/fail signal

The automatic check reports as the `jenkinsci/appliance-build-orchestrator` GitHub status check
on the PR. A manual `git ab-pre-push`/`git hotfix-build` run prints its own Jenkins build URL on
success; check that build's own result for pass/fail.
