# Local checks in this repo

How to run `appliance-build`'s local checks, to verify a change before relying on CI.

## There is no unit-test framework in this repo

`appliance-build` has no Java/Python/etc. unit-test suite. Its own Gradle `check` task runs two
things: `shfmtCheck` — a shell-script formatting check
(`shfmt -d` against every shell script under `scripts/`, the executable hooks under
`live-build/config/hooks`, `upgrade/prepare`, `upgrade/tests/*.sh`, and `upgrade/upgrade-scripts/`
except `README.md`, `rootfs-cleanup`, Python, and the Python stand-ins under
`tests/rootfs-cleanup-stubs/` and `tests/upgrade-container-tmp-datasets-stubs/`) — and
`checkTestingDocsVariantCoverage` (below).

`upgrade/tests/test-prepare.sh` exercises `upgrade/prepare` against a scratch `UPDATE_DIR`. Gradle
only formats it; run it by hand with `upgrade/tests/test-prepare.sh`. It needs no appliance, and
runs itself in a user namespace unless it is already root.

## Prerequisites

The Gradle wrapper here is 5.1, which requires Java 8 — select it explicitly
(`JAVA_HOME=<path to a Java 8 JDK>`) before running any `./gradlew` command below; this repo's own
bootstrap installs both `openjdk-8-jdk-headless` and `openjdk-17-jdk-headless`, so a default
`JAVA_HOME` pointed at 17 will fail. `shfmtCheck`/`shfmt` also invoke an external `shfmt`
executable that bootstrap does not install — it must already be on `PATH`.
`checkTestingDocsVariantCoverage` needs neither `shfmt` nor any particular Java version beyond
what the wrapper itself requires.

## Commands

```bash
./gradlew check            # runs shfmtCheck and checkTestingDocsVariantCoverage
./gradlew shfmtCheck       # shell-format check only — fails and prints a diff if anything is unformatted
./gradlew shfmt            # auto-fixes shell formatting in place
./gradlew checkTestingDocsVariantCoverage   # the variant/doc-coverage check below, on its own
```

## The variant/doc-coverage check (`checkTestingDocsVariantCoverage`)

A small, repo-local check (not a general-purpose test framework): it reads every directory name
under `live-build/variants/` (the same list
`gradle-lib/util.gradle`'s `allVariants` reads — see that file's own comment) and fails, naming
which variant(s) are missing, if any of them isn't mentioned as plain text somewhere under
`docs/testing/`. It passes silently otherwise.

This check is one-directional by design: it only catches a variant that exists but isn't
documented, not the reverse (a variant removed from `live-build/variants/` whose name is still
listed in `docs/testing/`). A stale mention is a doc-accuracy issue, not a build break, and
catching it would need parsing which words in the docs are actually variant mentions rather than
just checking for their presence.

## Two GitHub-Actions-gated per-PR checks

Defined in [`.github/workflows/main.yml`](../../.github/workflows/main.yml), both run on every
`pull_request` automatically — nothing to start by hand:

- `check-ansible` (the GitHub status-check name; runs `ansible/ansible-lint@main`) — lints every
  Ansible role/playbook in this repo.
- `check-shellcheck` (the GitHub status-check name; runs `ludeeus/action-shellcheck@master`) —
  lints shell scripts, with `gradlew` itself
  excluded (`ignore_names: gradlew`).

## Pass/fail signal

`./gradlew check` (and each task individually) exits non-zero and prints `BUILD FAILED` on any
failure, `BUILD SUCCESSFUL` otherwise. The two GitHub Actions jobs report as ordinary GitHub
status checks on the PR.
