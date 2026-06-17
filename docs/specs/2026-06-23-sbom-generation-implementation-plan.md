# SBOM Generation — Implementation Plan

- **Date:** 2026-06-23
- **Epic:** [CP-13455](https://perforce.atlassian.net/browse/CP-13455) — CycloneDX SBOM for Delphix engine product images
- **Design spec:** [CP-13456](https://perforce.atlassian.net/browse/CP-13456) — `docs/specs/2026-06-15-sbom-generation-design.md`

This plan sequences the design spec into incrementally-deliverable stories. Each phase
produces something usable on its own, so value lands before the whole effort is complete.

## Strategy

Build the consumer and producer halves independently, then connect them:

1. **appliance-build** first emits a per-image CycloneDX **base** (all installed debs) by
   running Syft on the chroot — a real, standard SBOM from day one, even before any
   1st-party depth.
2. **linux-pkg** independently starts emitting a per-package CycloneDX **sidecar** for
   every package (Syft-on-deb baseline, no overrides yet).
3. **appliance-build** then **merges** the 1st-party sidecars into the per-image base.
4. We **evaluate** whether the Syft-on-deb baseline is good enough for the two big Java +
   npm apps, or whether higher-fidelity producers (per-language tooling or Mend export)
   are needed — and file follow-ups accordingly.

Phases 1 and 2 have no dependencies and can proceed in parallel. Phase 3 needs both.
Phase 4 needs Phase 2.

## Verification & PR evidence policy

Every PR implementing a story below **must include, in its PR description, concrete proof
that each verifiable outcome was met** — or, if the work is split across PRs, explicit
evidence of what is still **pending**. "It builds" is not sufficient: show the BOM and show
it is correct. Acceptable proof is concrete and reviewer-checkable, e.g.:

- **Links to successful Jenkins jobs** (appliance-build / linux-pkg), not just "passed".
- **The S3 location** the artifact landed in (URI + a listing showing the `.cdx.json`).
- **The CycloneDX file contents** — attached or excerpted, schema-valid, and readable; for
  large files, include a representative excerpt plus how to retrieve the full file.
- **Reconciliation data** — counts/diffs that demonstrate correctness (see per-phase
  outcomes below).

A reviewer should be able to confirm the outcome from the PR description alone.

## Stories

### Phase 1 — [CP-13464](https://perforce.atlassian.net/browse/CP-13464): appliance-build base scan
Run Syft (dpkg cataloger) on the chroot rootfs → `<variant>-<platform>.cdx.json`;
schema-validate; wire into Gradle outputs + the existing S3 upload; provision Syft on the
build host. **Depends on:** nothing. **Deliverable:** a valid per-image CycloneDX of all
installed debs with `pkg:deb` PURLs.

**Verifiable outcomes (evidence in the PR):**
- A **successful appliance-build job** (Jenkins link) with evidence the
  `<variant>-<platform>.cdx.json` landed in the **correct S3 location** (the S3 URI + a
  listing showing the file).
- **The contents of the resulting CycloneDX file** (readable, schema-valid).
- **Package-set reconciliation:** provision a VM from that image and compare a count of
  `apt list --installed` against the `pkg:deb` components in the CycloneDX; the counts
  reconcile (explain any expected delta).

### Phase 2 — [CP-13465](https://perforce.atlassian.net/browse/CP-13465): linux-pkg per-package sidecar
Add a per-package **`SBOM_DEEP_SCAN`** opt-in flag (mirroring `MEND_SCAN_APPLICABLE`,
surfaced via `query-packages.sh`) plus a **CI lint** that fails on unclassified packages.
A baseline `generate_sbom()` in `lib/common.sh` runs Syft on each built `.deb` **only for
flagged 1st-party packages** → `<package>.cdx.json` in `$WORKDIR/artifacts/`; S3 upload
stores it beside the deb. No per-package overrides yet. 3rd-party forks are **not** scanned
(the appliance-build base scan already lists them flat). **Depends on:** nothing.
**Deliverable:** a CycloneDX sidecar in S3 next to each flagged package's deb.

**Verifiable outcomes (evidence in the PR):**
- For **each package that emits a sidecar** (`SBOM_DEEP_SCAN`): a **successful linux-pkg
  build job** (Jenkins link) with output/evidence the `<package>.cdx.json` was placed in
  the **correct S3 location**.
- **The CycloneDX file for each such package's deb(s)** (readable, schema-valid).

### Phase 3 — [CP-13466](https://perforce.atlassian.net/browse/CP-13466): appliance-build merge
Collect the available 1st-party sidecars (located via `COMPONENTS`; DCT/Hyperscale by
name) and merge each into the Phase 1 base (`cyclonedx-cli merge`), enriching the owning
`pkg:deb` component. Enrichment is driven by **sidecar presence**: a deb with no sidecar
(3rd-party fork, or a package not flagged for deep scan) correctly stays a flat component —
there is **no** blanket deb-scan fallback. **Depends on:** CP-13464, CP-13465.
**Deliverable:** per-image BOM with deep 1st-party composition.

**Verifiable outcomes (evidence in the PR):**
- A **successful appliance-build job** (Jenkins link).
- **The contents of the resulting merged CycloneDX file**, showing 1st-party deep
  components merged under their owning `pkg:deb` entries (readable, schema-valid).

### Phase 4 — [CP-13467](https://perforce.atlassian.net/browse/CP-13467): evaluate virtualization & masking
Validation diff per package across the candidate producers: Syft-on-deb vs. per-language
build-time tooling vs. **JFrog Xray** export (artifact scan) vs. **Mend** export (manifest
resolution). Both Xray and Mend are already integrated in the Delphix build and export
CycloneDX; both are **paid tools**, so weigh vendor lock-in against their near-free
integration. Key distinction: Mend resolves source manifests (sees the npm frontend),
while Xray scans the compiled `.deb` (may share Syft-on-deb's blind spots for bundled npm /
Rust — to be checked). Decide whether the baseline suffices or an override / SCA-tool
export is needed; file follow-ups. **Depends on:** CP-13465.

**Verifiable outcomes (evidence in the PR):**
- A written **comparison analysis** of component coverage — the new method vs. the current
  CSV BOM — for `delphix-virtualization` and `delphix-masking`, demonstrating the new
  output is **not worse** (no components lost; note any gains). Include the data/diff, not
  just a conclusion.

### Phase 5 — [CP-13486](https://perforce.atlassian.net/browse/CP-13486): zfs Rust SBOM override
The first concrete per-package deep-scan override. `zfs` is a fork of OpenZFS that also
ships Delphix's Rust object agent, whose crates are invisible to the Phase 2 Syft-on-deb
baseline. Set `SBOM_DEEP_SCAN="true"` for `zfs` and add an override in `packages/zfs/config.sh`
that derives the crate SBOM from `Cargo.lock` (`cargo-cyclonedx` / `cargo-auditable`+Syft,
`pkg:cargo` PURLs), merged into the `zfs` sidecar; supersedes the existing
`cargo-bundle-licenses` step. **Depends on:** CP-13465 (override mechanism + flag);
feeds the Phase 3 merge. `ptools` / `delphix-rust` are similar and get their own overrides
later.

**Verifiable outcomes (evidence in the PR):**
- A **comparison analysis** showing the new `zfs` SBOM is **not worse** than the current
  BOM's coverage (and, expected, that it now adds the `pkg:cargo` crate components the old
  method lacked).
- A **successful linux-pkg build job for `zfs`** (Jenkins link).
- **The contents of the resulting `zfs` CycloneDX file**, showing the Rust crates with
  `pkg:cargo` PURLs (readable, schema-valid).

### Decommission — [CP-13468](https://perforce.atlassian.net/browse/CP-13468)
After the new path is validated (and the publishing switch is in place), remove the
home-grown `devops-gate` `generate_bom.py`/`combine_bom.py` path and the legacy
license-capture steps in `linux-pkg`. Leave provenance, `COMPONENTS`, `copyright` files,
and Mend scanning in place. **Depends on:** Phases 1–3 + the publishing switch (below).

**Verifiable outcomes (evidence in the PR):**
- **Successful appliance-build and linux-pkg jobs** (Jenkins links) with the old
  `generate_bom`/`combine_bom` path removed, still producing the new CycloneDX BOM.
- Evidence the removed CSV is **no longer referenced** by any downstream step
  (publishing/upgrade), and that the upgrade/verification path is unaffected.

## Deferred (no stories yet)

Tracked in the design spec but intentionally **not** filed as stories at this stage:

- **DCT & Hyperscale SBOMs** — source SBOM generation for `delphix-dct` (apigw-services)
  and `delphix-hyperscale` (hyperscale-masking), plus the consumer's by-name
  classification and local-sidecar sourcing. Container-heavy; the spec flags them as
  priority once the core path works.
- **Customer-facing publishing switch** — update the `devops-gate` publishing automation
  (`appliance_build_stage0`, `release_stage`, `release_publish`, the Hyperscale publish
  job) to upload the CycloneDX file to the download site instead of the CSV. This is a
  prerequisite for the decommission story (CP-13468) and a customer-visible change needing
  product/release sign-off.

File these as stories under CP-13455 when the core phases are far enough along.

## Sequencing summary

```
CP-13464 (P1) ─┐
               ├─► CP-13466 (P3) ─► [publishing switch] ─► CP-13468 (decommission)
CP-13465 (P2) ─┤
       │       └─► CP-13486 (P5 zfs Rust override) ─┐
       │                                            └─► (enriches P3 merge)
       └─► CP-13467 (P4 eval) ─► [overrides / Mend follow-ups]
```
