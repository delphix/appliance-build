# Testing this repo

How to test and deploy a change to `appliance-build`: the local checks, the CI that runs (and how
to trigger more), and how to build an image and get it onto a VM. This is a different kind of
reference from this repo's own product docs (the root [`README.md`](../../README.md), the design
docs under [`docs/specs/`](../specs/)) — those explain the product and how to build it from
scratch; this set is commands, preconditions, and pass/fail signals.

## What's here

- [`unit-tests.md`](unit-tests.md) — how to run this repo's local checks.
- [`ci-runs.md`](ci-runs.md) — the CI that runs on a PR, and how to trigger more.
- [`deploy-to-vm.md`](deploy-to-vm.md) — how to build an image and get it onto a test VM.

## Current build variants

The appliance variants this repo currently defines, one directory per variant under
[`live-build/variants/`](../../live-build/variants/) (also the source `gradle-lib/util.gradle`'s
`allVariants` reads from — see that file's own comment): `external-dct`, `external-hyperscale`,
`external-standard`, `external-ucf`, `internal-buildserver`, `internal-claude`,
`internal-dcenter`, `internal-dct`, `internal-dev`, `internal-hyperscale`, `internal-minimal`,
`internal-package-mirror`, `internal-qa`, `internal-ucf`, `internal-unittest`. `./gradlew check`
(see [`unit-tests.md`](unit-tests.md)) fails if a variant exists here but isn't named anywhere
under `docs/testing/` — keep this list (or another file in this doc set) current with
`live-build/variants/` or that check will fail.
