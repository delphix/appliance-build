# SBOM Generation — `appliance-build` Design & Implementation Spec

- **Date:** 2026-06-25
- **Status:** In progress
- **Epic:** [CP-13455](https://perforce.atlassian.net/browse/CP-13455) — CycloneDX SBOM for Delphix engine product images
- **Related PR:** [#873](https://github.com/delphix/appliance-build/pull/873) (upstream design reference, superseded by this spec for appliance-build decisions)
- **Repo role:** Consumer — assembles per-image CycloneDX from Syft base scan + 1st-party sidecars

## Problem

Delphix appliance images ship without a machine-consumable SBOM. The only bill-of-materials
today is a home-grown CSV (`devops-gate generate_bom.py` / `combine_bom.py`) built by
brittle text-parsing of per-package `copyright` files — license-centric, no PURLs, and
not consumable by vulnerability scanners.

## Solution

Automatically generate a **CycloneDX 1.6 JSON** SBOM for **each platform × variant disk
image** produced by the appliance build. The primary consumer is vulnerability scanning
(Grype, Dependency-Track), so component coordinates must carry proper PURLs
(`pkg:deb/...`, `pkg:maven/...`, `pkg:npm/...`, `pkg:golang/...`, `pkg:cargo/...`).

## Full pipeline context

The initiative spans four repos. `appliance-build` is the **consumer** — it assembles
the per-image document. The other repos are producers:

```
linux-pkg (producer per package)
  generate_sbom() → <package>.cdx.json sidecar → S3 combined-packages/

apigw-services / hyperscale-masking (producers for DCT / Hyperscale)
  → delphix-dct.cdx.json / delphix-hyperscale.cdx.json → their own S3 artifact dirs

appliance-build (consumer, per image)
  Syft dpkg scan of chroot
    → base .cdx.json  (every installed deb flat)
    → fetch 1st-party sidecar SBOMs (via COMPONENTS + DCT/Hyperscale by name)
    → cyclonedx-cli merge  (enrich 1st-party deb entries with deep composition)
    → schema-validate
    → upload <variant>-<platform>.cdx.json to S3

devops-gate (publishing)
  → switch customer artifact: CSV → CycloneDX
  → decommission generate_bom.py / combine_bom.py
```

This spec covers only the `appliance-build` side in full detail. The producer and
publishing changes are owned by their respective repos.

**What this repo produces:** one `<variant>-<platform>.cdx.json` (CycloneDX 1.6 JSON) per
image build, containing:
- every installed Debian package as a flat `pkg:deb` component (3rd-party layer)
- each 1st-party package enriched with its deep composition (jars, npm, Go modules,
  Rust crates) sourced from per-package sidecar SBOMs produced by `linux-pkg` / DCT /
  Hyperscale builds

The output replaces the per-image `bom-<variant>-<platform>.csv` assembled today by
`devops-gate/jenkins/scripts/generate_bom/combine_bom.py`.

---

## Implementation phases in this repo

### Phase 1 — CP-13464: Base scan (no external dependencies)

**Deliverable:** a valid CycloneDX 1.6 document containing every installed deb as a
`pkg:deb` component, uploaded to S3 alongside the existing image artifacts.

#### What PR #876 already implements

`scripts/run-live-build.sh` — appended after the artifact-move loop (lines 211–215):

```bash
(
    SYFT_VERSION="v1.45.1"
    sbom_toolbin="${TOP}/live-build/build/.sbom-tools"
    mkdir -p "${sbom_toolbin}"
    if ! command -v syft >/dev/null 2>&1; then
        curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh |
            sh -s -- -b "${sbom_toolbin}" "${SYFT_VERSION}"
        export PATH="${sbom_toolbin}:${PATH}"
    fi
    syft scan "dir:${build_dir}/chroot" \
        --override-default-catalogers "dpkg-db-cataloger" \
        --source-name "${ARTIFACT_NAME}" \
        --source-version "${DELPHIX_APPLIANCE_VERSION:-unknown}" \
        -o "cyclonedx-json=${TOP}/live-build/build/artifacts/${ARTIFACT_NAME}.cdx.json"
) || echo "[sbom] WARNING: SBOM generation failed for ${ARTIFACT_NAME}; build continues." >&2
```

Key design choices already baked in:
- **dpkg-db-cataloger only** — reads `/var/lib/dpkg/status`, the authoritative installed-package
  set. Deep language catalogers are intentionally off; rootfs attribution is ambiguous
  (see parent design spec).
- **Best-effort subshell** — any failure prints a warning to stderr and does not set a
  non-zero exit on the parent script. The build succeeds without an SBOM.
- **`DELPHIX_APPLIANCE_VERSION`** — provided by the Gradle task environment; falls back
  to `unknown` if absent.

#### What remains in Phase 1

**1. CycloneDX schema validation**

After the Syft scan, validate the emitted document before treating it as good:

```bash
# inside the same subshell, after the syft scan
cyclonedx validate \
    --input-file "${TOP}/live-build/build/artifacts/${ARTIFACT_NAME}.cdx.json" \
    --input-format json \
    --input-version v1_6
```

`cyclonedx-cli` is a single Go binary (Anchore, Apache-2.0). Install it alongside
`syft` into `${sbom_toolbin}`. A validation failure should be treated the same as a
scan failure (warning, not a build break) until the pipeline is proven stable.

**2. S3 upload wiring**

The `.cdx.json` must be picked up by the same Gradle task that uploads
`.packages.list` and `.debs.tar.gz` today. The relevant Gradle property is
`AWS_S3_OUTPUT` / the `uploadArtifacts` task in `build.gradle`.

Locate the artifact-upload wiring in `build.gradle` and add `*.cdx.json` to the
file glob (or explicit list) of files shipped to S3. The file already lands in
`live-build/build/artifacts/` after PR #876, so no path change is needed — only
the upload registration.

**3. Syft host provisioning (build infrastructure)**

PR #876 installs Syft at build time via `curl` into `live-build/build/.sbom-tools/`.
This works but adds latency to every build and depends on reaching GitHub at build
time. The preferred state is Syft pre-installed on the build host (same as how
`live-build`, `aptly`, `ansible` are installed).

Until the build host is updated:
- The curl-based fallback in PR #876 is the accepted interim path.
- `SYFT_VERSION` is pinned (`v1.45.1`) in the script; update it here when upgrading.
- Track host-level provisioning as a follow-up with the infra team (no story filed yet).

---

### Phase 3 — CP-13466: Merge 1st-party sidecars (depends on Phase 1 + linux-pkg Phase 2)

**Deliverable:** the per-image `.cdx.json` enriched with deep composition for every
1st-party package that has a sidecar SBOM, so bundled jars, npm modules, Go modules,
and Rust crates appear as properly attributed nested components.

This phase has no work to start until `linux-pkg` Phase 2 (CP-13465) ships its first
sidecar SBOMs. The design below is ready to implement at that point.

#### Classification: 1st-party vs 3rd-party

The installed-package list is split using the existing
`/var/delphix-buildinfo/packages/COMPONENTS` file (shipped by `delphix-build-info`,
already present on every image):

```
COMPONENTS format: one entry per line
<deb-package-name>  <linux-pkg-package-name>  <version>  <s3-path>
```

Any installed deb whose name appears in `COMPONENTS` is 1st-party and may have a
sidecar. Debs not in `COMPONENTS` are 3rd-party forks or upstream packages — they
stay as flat `pkg:deb` components in the base document.

Two packages are classified separately (not in `COMPONENTS`):
- `delphix-dct` → sidecar at `$WORK/artifacts/dct/delphix-dct.cdx.json`
- `delphix-hyperscale` → sidecar at `$WORK/artifacts/hyperscale/delphix-hyperscale.cdx.json`

These are already synced locally by `download_dct_artifacts()` /
`download_hyperscale_artifacts()` in `scripts/common.sh`. No new fetch logic is needed.

#### Sidecar fetch for `combined-packages` packages

For each 1st-party package identified via `COMPONENTS`, fetch its sidecar from S3:

```
s3://<combined-packages-bucket>/packages/<linux-pkg-package-name>/<package>.cdx.json
```

The S3 path is derivable from the `<s3-path>` column in `COMPONENTS` (strip the
`.deb` filename to get the directory). The sidecar lives beside the `.deb`.

Fetch is best-effort per package: a missing sidecar means the package has not yet
opted into `SBOM_DEEP_SCAN` in `linux-pkg` — the flat `pkg:deb` component in the base
document correctly stands. Do not fall back to a Syft scan of the deb; see the
parent design spec for why (attribution ambiguity for 3rd-party forks).

Optional guard (implement when the pipeline is stable): if `COMPONENTS` is extended
to carry the `SBOM_DEEP_SCAN` flag, warn when a flagged package has no sidecar —
this catches a producer regression without blocking the build.

#### Merge

Use `cyclonedx-cli merge` to combine the base document with each collected sidecar:

```bash
# pseudocode — real invocation TBD based on cyclonedx-cli merge interface
cyclonedx merge \
    --input-files "${base_cdx}" "${sidecar1}" "${sidecar2}" ... \
    --output-file "${merged_cdx}" \
    --output-format json
```

The merge links each sidecar's components as nested children of the owning `pkg:deb`
entry and adds `dependencies` edges — the final document is valid for Grype,
Dependency-Track, and other tools that flatten or traverse the graph.

Install `cyclonedx-cli` alongside `syft` in `${sbom_toolbin}`.

#### Assembler location

Add a new script `scripts/generate-sbom.sh` (or inline in `run-live-build.sh` if the
logic stays compact). Inputs:
- `${build_dir}/chroot` — chroot rootfs (for Phase 1 base scan)
- `${build_dir}/chroot/var/delphix-buildinfo/packages/COMPONENTS` — classification
- `$WORK/artifacts/dct/` and `$WORK/artifacts/hyperscale/` — DCT/Hyperscale sidecars
- `${TOP}/live-build/build/artifacts/${ARTIFACT_NAME}.cdx.json` — Phase 1 base output

Output: `${TOP}/live-build/build/artifacts/${ARTIFACT_NAME}.cdx.json` (overwritten
in-place with the merged, enriched document).

Hook point in `run-live-build.sh`: immediately after the Phase 1 scan, still within
the same best-effort subshell.

---

## Artifacts produced

All land in `${TOP}/live-build/build/artifacts/` alongside existing outputs:

| File | Phase | Description |
|---|---|---|
| `<ARTIFACT_NAME>.cdx.json` | 1 | CycloneDX 1.6 JSON — flat debs only initially, enriched with 1st-party depth after Phase 3 |
| `<ARTIFACT_NAME>.debs.tar.gz` | existing | All Debian packages |
| `<ARTIFACT_NAME>.<vm_ext>` | existing | VM image (ova / vmdk / qcow2 / vhdx / gcp.tar.gz) |
| `<ARTIFACT_NAME>.packages.list` | existing | Flat `name=version` list (retained; verify upgrade dependency before removing) |

`ARTIFACT_NAME` = `<APPLIANCE_VARIANT>-<APPLIANCE_PLATFORM>`, e.g. `internal-minimal-esx`.

---

## Tooling

Both tools are Go binaries, Apache-2.0, installed on the build host (or fetched at
build time into `live-build/build/.sbom-tools/` as an interim):

| Tool | Version | Purpose |
|---|---|---|
| `syft` | v1.45.1 (pinned) | Generate base CycloneDX from chroot dpkg database |
| `cyclonedx-cli` | TBD | Validate + merge CycloneDX documents |

Neither tool is installed inside the shipped appliance image. They run on the build
host only.

---

## Document structure (CycloneDX 1.6 JSON)

```
metadata:
  component:
    name:    <APPLIANCE_VARIANT>-<APPLIANCE_PLATFORM>
    version: <DELPHIX_APPLIANCE_VERSION>
    type:    "operating-system"
  timestamp: <build time>
  tools:
    - name: syft,    version: <SYFT_VERSION>
    - name: cyclonedx-cli (Phase 3+)

components[]:
  # 3rd-party debs — flat, from Syft dpkg scan
  - type: library, purl: pkg:deb/ubuntu/<name>@<version>

  # 1st-party debs — enriched after Phase 3
  - type: library, purl: pkg:deb/.../<name>@<version>
    components[]:           # nested: bundled jars, npm, Go modules, Rust crates
      - type: library, purl: pkg:maven/...
      - type: library, purl: pkg:npm/...
      - ...

dependencies[]:
  # bom-ref graph linking each 1st-party deb to its bundled children
  # (required for Dependency-Track / Grype flattenors)
```

---

## Validation

**Schema validation (Phase 1):** `cyclonedx validate` on every emitted document.
A malformed SBOM fails with a warning (best-effort) rather than shipping silently.

**End-to-end validation (before customer publishing switch):**
1. Feed a generated `.cdx.json` through Grype — confirm `pkg:deb` PURLs resolve to
   CVEs as expected.
2. Diff component coverage against a current `generate_bom` / `combine_bom` run —
   confirm no package present in the old CSV is missing from the new CycloneDX document.

---

## CI

`.github/workflows/main.yml` currently runs `ansible-lint` + `ShellCheck` only (no
full build). New shell in `scripts/run-live-build.sh` and any new `scripts/generate-sbom.sh`
gets ShellCheck coverage automatically. Actual SBOM generation runs only in the real
Jenkins build.

No new CI jobs are needed for Phase 1. Consider adding a dry-run SBOM test (Syft scan
of a minimal chroot fixture) to the workflow for Phase 3 regression coverage.

---

## Dependencies on other repos

| Dependency | Repo | Jira | Blocks |
|---|---|---|---|
| Per-package sidecar SBOMs in S3 | `linux-pkg` | CP-13465 | Phase 3 |
| `delphix-dct.cdx.json` sidecar in DCT artifact dir | `apigw-services` | (deferred) | Phase 3 DCT enrichment |
| `delphix-hyperscale.cdx.json` sidecar in Hyperscale artifact dir | `hyperscale-masking` | (deferred) | Phase 3 Hyperscale enrichment |
| Customer publishing switch | `devops-gate` | CP-13468 | Decommission |

Phase 1 (base scan + validation + S3 upload) has **no external dependencies** and can
ship independently.

---

## What is NOT in scope for this repo

- Generating per-package SBOMs for `linux-pkg` packages — that is `linux-pkg` work
  (CP-13465).
- Per-language build-time SBOM generation for `masking`, `virtualization`, DCT,
  Hyperscale — those are source-repo tasks (CP-13467 evaluation).
- Customer-facing publishing automation switch from CSV → CycloneDX — that is
  `devops-gate` work (CP-13468).
- Removing `.packages.list` as the inventory-of-record — verify upgrade/verification
  dependency first; retain the file itself regardless.
- Installing Syft/cyclonedx-cli inside the appliance image — build-host tools only.

---

## Open questions

1. **`cyclonedx-cli merge` interface** — confirm the exact flags for merging multiple
   sidecars into a base document while preserving nested component attribution. The
   parent spec references `cyclonedx-cli merge` but the exact invocation depends on
   the CLI version chosen.

2. **S3 sidecar fetch mechanism** — confirm whether the assembler fetches sidecars
   directly from S3 during the build (requires AWS credentials at that build stage) or
   whether they should be pre-downloaded alongside the `.deb`s. The `combined-packages`
   sync in `scripts/common.sh` is the natural place to add sidecar fetch.

3. **`COMPONENTS` format and `SBOM_DEEP_SCAN` propagation** — confirm whether
   `linux-pkg` Phase 2 extends `COMPONENTS` to carry the `SBOM_DEEP_SCAN` flag, or
   whether the assembler infers sidecar presence purely from file existence on S3.

4. **Syft version pinning** — `v1.45.1` is pinned in PR #876. Establish an update
   cadence (quarterly? on CVE?) and owner.

5. **`.packages.list` removal prerequisite** — before demoting `.packages.list` from
   inventory-of-record, confirm whether the upgrade verification path (likely
   `upgrade/` scripts or the `delphix-entire` metapackage `template.ctl` `Extra-Files`)
   depends on it.

6. **Performance** — 91 possible variant × platform combinations. The base scan
   (Syft dpkg) is fast (metadata-only, not content hashing). Phase 3 merge latency
   depends on number of 1st-party sidecars and their size. Measure on a representative
   image and confirm it fits within the build time budget before Phase 3 ships.

---

## Sequencing summary

```
PR #876 (merged) ──► Phase 1 remainder ──────────────────────► Phase 3
                      · schema validation                        · COMPONENTS classification
                      · S3 upload wiring                         · sidecar fetch
                      · host provisioning (infra follow-up)      · cyclonedx-cli merge
                                                                 · DCT/Hyperscale enrichment
                             ▲
                    no external deps                    blocked on: linux-pkg CP-13465
                                                        (+ DCT/Hyperscale sidecar work)

Phase 3 ──► [customer publishing switch in devops-gate] ──► decommission generate_bom/combine_bom
```
