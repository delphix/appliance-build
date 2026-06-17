# SBOM Generation for Appliance Images — Design

- **Date:** 2026-06-15
- **Status:** Design / feasibility (approved for planning)
- **Repos affected:** `appliance-build` (consumer), `linux-pkg` (producer),
  `devops-gate` (pipeline scripts being replaced), and the first-party source repos that
  generate their own SBOMs: `dms-core-gate` (masking), `dlpx-app-gate` (virtualization),
  `apigw-services` (DCT), `hyperscale-masking` (Hyperscale)

## Goal

Automatically generate a Software Bill of Materials (SBOM) in **CycloneDX 1.6 JSON**
format for **each platform × variant disk image** produced by the appliance build.

The primary consumer is **vulnerability scanning** (e.g. Grype, Dependency-Track),
so component coordinates must be accurate enough that a scanner can match them
against CVE databases — meaning proper PURLs (`pkg:deb/...`, `pkg:maven/...`,
`pkg:pypi/...`, `pkg:npm/...`, `pkg:golang/...`, `pkg:cargo/...`), not bare
`name=version` strings.

## Scope of inventory

Two package categories, with deliberately different depth:

- **3rd-party Debian packages** → **apt-level only**. One flat `deb` component per
  package (name, version, `pkg:deb` PURL, license if available). No deep scan.
- **1st-party packages** (built in `linux-pkg` from Delphix source) → **deep
  composition**. These bundle third-party components across multiple ecosystems
  (jars, npm, Python wheels, Go modules, Rust crates), and each bundled component
  must appear so it can be vuln-scanned.

Classification of installed packages into 1st- vs 3rd-party uses the existing
first-party component list shipped by the `delphix-build-info` package at
`/var/delphix-buildinfo/packages/COMPONENTS`.

## Key decision: generate 1st-party composition upstream, in `linux-pkg`

Deep composition is most accurate when computed **at the component's build time**,
where the source and its dependency manifests (`Cargo.lock`, `pom.xml`/Gradle,
`package-lock.json`, `go.mod`, `poetry.lock`) are present.

A post-hoc scan of a built `.deb` cannot recover everything. In particular,
**Rust crate composition is invisible in a stripped compiled binary** unless it was
built with embedded metadata — that signal exists only at build time. Because
`linux-pkg` builds 1st-party packages from source, generating the SBOM there closes
the Rust gap by construction.

Using a **deep filesystem scan to recover 1st-party composition** is explicitly
rejected: a jar/wheel/binary found on the rootfs cannot be cleanly attributed to the
package that placed it (dpkg tracks directly-placed files, but vendored/extracted/
generated content is not individually attributed). 1st-party depth therefore comes from
the source build, not a rootfs scan.

This is **not** the same as refusing to run Syft on the chroot at all. Syft's **dpkg
cataloger** reads `/var/lib/dpkg/status`, which authoritatively lists every installed
package with its version — no attribution ambiguity. The consumer uses exactly that to
generate the base document (every installed deb as a `pkg:deb` component), then enriches
the 1st-party entries with their source-built SBOMs. The thing we avoid is turning on
Syft's *deep language catalogers* against the whole rootfs, which is where attribution
breaks down.

## Architecture diagram

```
    +------------------------------------------------------------------------+
    | linux-pkg   --   PRODUCER                                              |
    | (runs once per package build)                                          |
    |                                                                        |
    |   build()  -->  .deb(s)                                                |
    |                                                                        |
    |   generate_sbom()   [only if SBOM_DEEP_SCAN]:                          |
    |     baseline : syft scans the built .deb                               |
    |     override : cargo-cyclonedx / cyclonedx-gradle / cyclonedx-gomod    |
    |                (higher fidelity)                                       |
    +------------------------------------+-----------------------------------+
                                         |
                                         |  emits  <package>.cdx.json
                                         |  (sidecar next to the .deb)
                                         v
    +------------------------------------------------------------------------+
    | S3 :  combined-packages/   (+ DCT / Hyperscale artifact dirs)          |
    |          packages/<pkg>/                                               |
    |            *.deb                                                       |
    |            <package>.cdx.json      <-- sidecar SBOM (1st-party only)   |
    |          COMPONENTS   (maps deb -> 1st-party package)                  |
    +------------------------------------+-----------------------------------+
                                         |
                                         |  downloaded during the build
                                         v
    +------------------------------------------------------------------------+
    | appliance-build   --   CONSUMER                                        |
    | (runs once per platform x variant image)                               |
    |                                                                        |
    |   syft scans the chroot rootfs (dpkg cataloger)                        |
    |                                    |                                   |
    |                                    v                                   |
    |   base CycloneDX: every installed deb as a                             |
    |   pkg:deb component (name, version, PURL)                              |
    |                                    |                                   |
    |                                    v                                   |
    |   for each deb that has a sidecar SBOM                                 |
    |   (1st-party: SBOM_DEEP_SCAN, + dct / hyperscale):                     |
    |     merge it in  (enrich the deb component)                            |
    |   no sidecar -> stays a flat deb component                             |
    |                                    |                                   |
    |                                    v                                   |
    |   <variant>-<platform>.cdx.json                                        |
    +------------------------------------+-----------------------------------+
                                         |
                                         |  uploaded to S3 with the
                                         |  other image artifacts
                                         v
               Grype / Dependency-Track   (vulnerability scan)
```

The DCT and Hyperscale components (built outside `linux-pkg`) follow the same
producer → sidecar → consumer pattern, but publish their `.cdx.json` to their own S3
artifact directories instead of `combined-packages`. See *First-party components built
outside `linux-pkg`* below.

## Architecture — producers and consumer

Producers generate per-package CycloneDX SBOMs at build time (most via `linux-pkg`; DCT
and Hyperscale via their own builds). The single consumer, `appliance-build`, collects
them and merges one document per image.

### `linux-pkg` (producer)

Generates a per-package CycloneDX SBOM at build time and stores it beside the
`.deb`(s) as a sibling artifact, uploaded to S3 with the package.

`linux-pkg` already drops sidecar metadata (`BUILD_INFO`, `GIT_HASH`, …) into
`$WORKDIR/artifacts/` via `store_build_info()` in `lib/common.sh`. The SBOM is just
another sibling artifact in that directory — no new artifact-routing pattern needed.

**Only packages that bundle third-party composition get a linux-pkg SBOM.** linux-pkg
builds two kinds of packages from source: **1st-party** (Delphix-authored apps that bundle
third-party components — jars, npm, wheels, crates) and **3rd-party forks**
(forked/repackaged upstream projects). A plain 3rd-party fork *is* the component; the
appliance-build base chroot scan already lists it as a flat `pkg:deb` component, so a
linux-pkg deep scan would add nothing.

The gate is therefore "does this package bundle third-party composition," not strictly
"is it 1st-party." That criterion catches the 1st-party apps **and** a few forks that
ship their own dependency tree — notably **`zfs`**, a fork of OpenZFS that also bundles
Delphix's Rust object agent (its crates are invisible to a deb scan; see the per-ecosystem
overrides). This is exactly why the annotation is an action flag (`SBOM_DEEP_SCAN`) rather
than a first-party/third-party label.

**Annotation — `SBOM_DEEP_SCAN` in `config.sh`:** a per-package opt-in boolean, mirroring
the existing `MEND_SCAN_APPLICABLE` convention and surfaced through `query-packages.sh`.
Default is off (no deep scan). A package that bundles third-party composition sets
`SBOM_DEEP_SCAN="true"`. To prevent a new 1st-party package from silently slipping through,
a **CI lint** in linux-pkg fails when a package is unclassified (neither flagged for deep
scan nor explicitly marked as not needing it).

**Baseline — `generate_sbom()` in `lib/common.sh`:**

- Runs **Syft** on the built `.deb`(s) and emits CycloneDX — **only when `SBOM_DEEP_SCAN`
  is set.** Called from / immediately after `store_build_info()`, after the `.deb`s exist
  and before upload.
- Produces a `<package>.cdx.json` sidecar (uploaded beside the deb) for each flagged
  1st-party package. 3rd-party forks produce **no sidecar** by design — they are covered by
  the consumer's base scan.

**Per-ecosystem overrides (incremental, higher fidelity):**

Added in a package's `config.sh`, mirroring how packages already override `build()`:

- **Rust** (`zfs`, `ptools`, `delphix-rust`) → `cargo-cyclonedx` / `Cargo.lock`.
  **First override to implement — closes the Rust gap.**
- **Java/Gradle** (`masking`, `delphix-sso-app`, `containerized-masking`,
  `windows-connector`) → `cyclonedx-gradle-plugin` (upgrade from the existing
  `generateLicenseReport`).
- **Go** (`delphix-go`) → `cyclonedx-gomod`, or rely on Syft's Go-binary cataloger.

### First-party components built outside `linux-pkg` (DCT, Hyperscale)

Two first-party components are **not** built by `linux-pkg` and do not flow through
`combined-packages`:

- **`delphix-dct`** — built from `apigw-services` (Gradle/Java backend + an Angular/npm
  UI + Python AI services + bundled **container images** based on Alpine/OpenResty/
  Postgres). Published to its own S3 path
  (`…/jenkins-ops/dct/develop/post-push/latest`).
- **`delphix-hyperscale`** — built from `hyperscale-masking` (multi-module Gradle/Java +
  many bundled **container images**). Published to its own S3 path
  (`…/hyperscale-masking/build/debian-pkg/develop/latest`).

`appliance-build` already syncs each component's full S3 directory (validated against
`SHA256SUMS`) via `download_dct_artifacts()` / `download_hyperscale_artifacts()` in
`scripts/common.sh`, pools the `.deb`s into the ancillary repo, and installs
`delphix-dct` / `delphix-hyperscale` via apt — but **only** in the `*-dct` / `*-hyperscale`
variants (selected by the `dct-common` / `hyperscale-common` ansible roles).

**Contract:** each of these builds must generate a CycloneDX SBOM and place it as a
**sidecar in the same S3 artifact directory** appliance-build already syncs (e.g.
`delphix-dct.cdx.json`, `delphix-hyperscale.cdx.json`), included in that directory's
`SHA256SUMS`. Because appliance-build syncs the whole directory, the SBOM arrives locally
in `$WORK/artifacts/dct/` (resp. `hyperscale/`) with no new fetch logic — the assembler
reads it from there.

Because the bulk of what these `.deb`s contain is **container images**, the
highest-fidelity SBOM must be produced at their source build (Syft over the image
tarballs for the in-container OS + language layers, plus `cyclonedx-gradle-plugin` /
`npm sbom` / `cyclonedx-python` for the app source, merged). A post-hoc deb-scan in
appliance-build would have to crack open opaque container tarballs and is a poor fallback
— another reason to produce these upstream.

### `appliance-build` (consumer)

The consumer does **not** hand-build CycloneDX. Syft already emits valid CycloneDX from a
filesystem, so the design is "let Syft generate the base document, then enrich the
1st-party entries" rather than "construct components from dpkg output in a script." This
keeps the custom code to classification + merge.

Per-image flow:

1. **Generate the base document with Syft.** Run Syft on the chroot rootfs with the
   **dpkg cataloger** → a CycloneDX document containing every installed package as a
   `pkg:deb` component (name, version, PURL, license where dpkg records it). This is the
   whole 3rd-party layer, for free, with no bespoke component construction. (Deep language
   catalogers stay **off** here — see the attribution note above.) Set
   `metadata.component` to the image (`<variant>-<platform>`).
2. **Collect available 1st-party sidecar SBOMs.** Sidecars exist **only** for packages
   that opted into a deep scan (`SBOM_DEEP_SCAN` in linux-pkg) plus DCT/Hyperscale:
   - combined-packages packages → the sibling SBOM from the package's `combined-packages`
     S3 path (located via `/var/delphix-buildinfo/packages/COMPONENTS`);
   - `delphix-dct` / `delphix-hyperscale` → the sidecar synced into
     `$WORK/artifacts/dct/` / `hyperscale/` (they are not in `COMPONENTS`).
3. **Enrich by sidecar presence.** For each installed package that has a sidecar, merge it
   into the base, linking its deep components to the owning `pkg:deb` entry (nested
   components and/or a `dependencies` edge). A standard CycloneDX merge (`cyclonedx-cli
   merge`, or Syft source enrichment) does this — no hand-authored JSON.
   - **No sidecar → leave the flat component.** This is the correct, intended outcome for
     3rd-party forks (and any package not flagged for deep scan): the base scan's flat
     `pkg:deb` component stands. There is deliberately **no** blanket deb-scan fallback —
     it would wrongly deep-scan forks and reintroduce the attribution problem.
   - *(Optional guard:)* if the `SBOM_DEEP_SCAN` flag is propagated to appliance-build
     (e.g. via `COMPONENTS` or build-info), a flagged package that is *missing* its sidecar
     can warn/fail instead of silently shipping flat — catching a producer regression.
4. **Emit + validate** `live-build/build/artifacts/<variant>-<platform>.cdx.json` and
   schema-check it. Because the base is whatever Syft found installed,
   DCT/Hyperscale components appear only in the `*-dct` / `*-hyperscale` images
   automatically — no variant-specific branching.

So the assembler is essentially: *Syft base scan* + *fetch the available 1st-party
sidecars* + *CycloneDX merge* — orchestration around existing tools, not a CycloneDX
generator.

Hook point: a new artifact-generation step invoked from `scripts/run-live-build.sh`
in the artifact stage (alongside where `.packages.list` / `.debs.tar.gz` are produced
today, ~lines 190–215). The output is picked up by the same Gradle/Jenkins path that
already ships `.packages.list` to S3 (`AWS_S3_OUTPUT`) — no new artifact-routing
plumbing.

## SBOM document structure (CycloneDX 1.6 JSON)

- `metadata.component` = the image (`name: <variant>-<platform>`,
  `version: <DELPHIX_APPLIANCE_VERSION>`).
- `metadata.timestamp` + `metadata.tools` (this generator + Syft version) for
  provenance.
- `components[]` = every package.
  - 3rd-party debs are flat.
  - Each 1st-party deb is a `deb` component with its bundled third-party components as
    **nested `components[]`** (jars, wheels, npm, Go modules, Rust crates), so
    attribution is explicit in the structure.
- `dependencies[]` = bom-ref graph linking each 1st-party deb to its bundled children,
  keeping the document valid for tools that flatten (Dependency-Track, Grype).

This structure is produced mechanically, not by hand: Syft emits the flat `pkg:deb`
components (the base), and the 1st-party merge adds each package's nested components and
`dependencies` edges. An upstream cargo-generated SBOM for a Rust component, say, simply
populates that deb's nested-component subtree during the merge.

## The S3 sidecar contract

- **Format:** CycloneDX 1.6 JSON, one SBOM per package build.
- **Location:** beside the `.deb`(s) in the package's `combined-packages` S3 path
  (the `/post-push/` directory `appliance-build` already pulls from).
- **Association:** `appliance-build` maps an installed `.deb` → its owning 1st-party
  package via `/var/delphix-buildinfo/packages/COMPONENTS`, then pulls that package's
  SBOM once.

## Tooling

- **Syft** (Anchore, Apache-2.0) — native CycloneDX output, multi-ecosystem catalogers
  (dpkg, Java jars via `pom.properties`, Python dist-info, npm `package.json`, Go
  binary build-info), proper PURLs. A single Go binary, installed on the **build host**
  in both repos — never inside the shipped image.
- **Per-ecosystem native tools** for high-fidelity overrides: `cargo-cyclonedx`,
  `cyclonedx-gradle-plugin`, `cyclonedx-gomod`.
- A small **assembler** in `appliance-build` (shell/Python, following existing
  `scripts/` conventions) for classify + fetch/fallback + merge.

## Performance across the platform × variant matrix

There are up to 91 platform × variant combinations. The expensive deep work now
happens **once per package version in `linux-pkg`**, not per image. In
`appliance-build`, 1st-party handling is mostly a fetch + merge, and 3rd-party
handling is pure dpkg metadata — both cheap. The per-image cost is dominated by
merge/serialize, roughly proportional to the number of installed packages. The
deb-content hash-cache that an appliance-build-only design would need is largely
unnecessary because the SBOM already exists per package-version upstream; it remains
only as an optimization for the fallback scan path.

## CI / validation

- `.github/workflows/main.yml` currently runs only ansible-lint + ShellCheck (no full
  build), so new shell/Python gets lint coverage there; actual SBOM generation runs in
  the real Jenkins build.
- Add **CycloneDX schema validation** of every emitted document so a malformed SBOM
  fails the build rather than shipping silently.
- **End-to-end validation:** feed a generated image SBOM through a scanner
  (Grype / Dependency-Track) and confirm PURLs resolve to CVEs as expected.

## Existing mechanism being replaced

There is a home-grown build-metadata mechanism today whose architecture loosely
resembles this one — some data is produced during package builds, the rest assembled
during the appliance build. It is **not** a standard SBOM; it is provenance plus
ad-hoc license capture.

**Producer side (`linux-pkg`):** `store_build_info()` in `lib/common.sh` writes
per-package sidecar files into `$WORKDIR/artifacts/` — `GIT_HASH`, `BUILD_INFO`,
`KERNEL_VERSIONS`, `PACKAGE_DEPENDENCIES`, `PACKAGE_MIRROR_URL_*`. A handful of
packages add ad-hoc dependency/license capture:

- `masking`, `virtualization` → Gradle `generateLicenseReport` → `dependency-license/*`,
  plus a hand-rolled `metadata.json` (git-hash + date).
- `zfs` → `cargo-bundle-licenses`.
- `misc-debs` → `BUILD_INFO` listing fetched debs + SHA256.

Separately, vulnerability coverage today relies on **Mend** scans wired per-package via
the `MEND_SCAN_APPLICABLE` flag (4 packages), independent of any unified document.

**Consumer side (`appliance-build`):** `scripts/create-build-info-package.sh` collects
those per-package sidecars (via the S3 `combined-packages` aggregation and its
`COMPONENTS` file) into the `delphix-build-info` `.deb`, installed at
`/var/delphix-buildinfo/` on the image. `81-upgrade-repository.binary` additionally
emits `<variant>-<platform>.packages.list` (flat `name=version`) and `.debs.tar.gz`.

**The actual BOM file** is assembled by the appliance-build Jenkins pipeline using
home-grown scripts in `devops-gate` at `jenkins/scripts/generate_bom/`:

- `generate_bom.py` walks the built `.deb`s and extracts a BOM by **text-parsing the
  `copyright` file embedded in each `.deb`** — with bespoke, format-specific parsers per
  package (`virtualization`, `masking`, `delphix-sso-app` have hand-written parsers for
  their `Group:/Name:/Version:`, `POM License:`, and `Dependency License Report for NPM
  Packages` / `Adding external licenses` sections), a special case that un-gzips
  `THIRDPARTYLICENSES.gz` (a JSON file) for ZFS, and a generic `License:`-line parser for
  the rest. It carries hardcoded `ignore_packages`, `ignore_licenses`,
  `commercial_licenses`, and `custom_licenses` lists and per-product dedup.
- `combine_bom.py` runs **per variant × platform**, merging the master `bom.csv` with
  that image's `.packages.list` into `bom-<variant>-<platform>.csv` (columns
  `product, package, version, license, license_url`).

This is orchestrated by `devops-gate`'s `jenkins/jobs/pipelines/appliance_build_stage0.groovy`
(the `generate_bom` / `combine_bom` invocations and `archiveArtifacts 'bom*.csv'`). The
master `bom.csv` is per build (classified by product: Linux Package / Virtualization /
Masking / ZFS); the per-image CSVs are derived from it plus each image's flat package
list — the per-image file is the master license table filtered against a package list,
not an independently-computed per-image composition.

### What is replaced vs. retained

Per the agreed scope, only the SBOM-relevant parts are replaced; the provenance and
classification machinery is load-bearing for the new design and for unrelated
functions, so it stays.

**Replaced** (superseded by per-package CycloneDX SBOMs + the new assembler):

- The `devops-gate` BOM scripts `jenkins/scripts/generate_bom/generate_bom.py` and
  `combine_bom.py` — the brittle copyright-file text-parsing, the `THIRDPARTYLICENSES.gz`
  special case, and the hardcoded package/license classification lists all go away,
  replaced by structured CycloneDX consumed directly.
- The ad-hoc license/dependency capture in `linux-pkg`: the `generateLicenseReport`
  copy steps in `masking`/`virtualization`, the `cargo-bundle-licenses` step in `zfs`,
  and the bespoke per-package `metadata.json`.
- `.packages.list` as the **inventory-of-record** for component/vuln purposes — the
  image CycloneDX document becomes the authoritative inventory.

**Retained** (reused by the new design and/or serving other functions):

- `/var/delphix-buildinfo/` provenance tree (git hashes, build context) — used by
  on-appliance support/diagnostics; out of scope to remove.
- `COMPONENTS` — the new design's 1st-party classification depends on it.
- `store_build_info()` provenance files (`GIT_HASH`, `BUILD_INFO`, etc.).
- **Mend** per-package scanning — not removed; it may instead be *extended* to export
  the per-package CycloneDX SBOM for the four `.whitesource` repos (see *SBOM method for
  these four repos*).

**Verify before removal:** `.packages.list` is bundled into the `delphix-entire`
metapackage (`template.ctl` `Extra-Files`) and is likely consumed by upgrade
verification. Confirm no upgrade/verification path depends on it before removing or
demoting it; if it does, retain the file and only stop treating it as the SBOM.

## Why the new approach is better than the existing one

1. **It is an actual SBOM in a recognized standard.** The existing output is a custom
   Delphix format (scattered text files + non-standard license reports) that no
   off-the-shelf scanner can consume. CycloneDX 1.6 is consumed directly by Grype,
   Dependency-Track, and others — no bespoke tooling to build or maintain.
2. **Standard tooling instead of home-grown logic.** The old mechanism *does* capture
   the third-party components bundled inside first-party packages — but through bespoke,
   hand-maintained machinery: the `com.github.jk1` Gradle license-report plugin,
   `npm-license-crawler`, custom `buildSrc` post-processors (`AddExternalLicenses.java`,
   `JsonReportImporter.java`), and hand-curated `license_index*.json` files per repo.
   The new approach replaces that with maintained, standard SBOM generators
   (`cyclonedx-gradle-plugin`, `npm sbom`/`cyclonedx-npm`, `cargo-cyclonedx`, Syft) — far
   less bespoke code for Delphix to own, and output that interoperates by construction.
3. **Vulnerability-oriented coordinates, not license-centric reports.** Today's output
   is license-focused (CSV / `THIRD-PARTY-NOTICES.txt` / custom `index.xml`) — it carries
   coordinates and license text, but in formats no scanner consumes and without the
   PURLs/CPEs a CVE matcher needs. CycloneDX components carry PURLs (and CPEs), turning a
   human-readable license listing into a machine-scannable bill of materials.
4. **Coverage is uniform, not ad-hoc.** Today only a few packages capture dependency
   data, each via a different tool, in different formats, none assembled into a single
   document. In the new design the consumer's base chroot scan covers **every** installed
   deb from day one, and the flagged 1st-party packages (`SBOM_DEEP_SCAN`) add their deep
   composition consistently on top — one mechanism, not a patchwork.
5. **Structured assembly instead of brittle parsing.** The old mechanism *does* assemble
   a BOM (`generate_bom.py` + `combine_bom.py`, per variant × platform), but it does so by
   **text-parsing human-readable `copyright` files** out of each `.deb`, with
   format-specific parsers per package, a one-off `THIRDPARTYLICENSES.gz` path for ZFS,
   and hardcoded ignore/commercial/custom classification lists — fragile to any upstream
   change in a copyright file's wording or layout. The new design consumes structured
   CycloneDX produced by the components themselves: nothing to text-parse, no per-package
   special-casing, and each per-image document is an actual composition rather than a
   master license table filtered against a flat package list.
6. **It is an evolution, not a foreign system.** It reuses the same
   produce-at-package-build + assemble-at-appliance-build shape the team already
   operates (and the same `COMPONENTS`/`combined-packages` plumbing), so it replaces
   the weak parts without introducing an unfamiliar architecture.

## First-party source-repo changes

Most first-party packages need **no source-repo change**: the baseline `generate_sbom()`
(Syft-on-deb) covers them, and the Rust packages are handled by a `cargo-cyclonedx`
override that runs in `linux-pkg` against the checked-out source (reads `Cargo.lock`) —
no change in the component repo itself. (`zfs` currently runs `cargo-bundle-licenses`;
that step is superseded by the CycloneDX override.)

The packages that warrant a closer look are the Java + npm + container applications —
`masking` (`dms-core-gate`), `virtualization` (`dlpx-app-gate`), `dct` (`apigw-services`),
and `delphix-hyperscale` (`hyperscale-masking`) — whose composition spans ecosystems and
bundled UIs that the simple Syft-on-deb baseline does not fully capture.

### Why Syft-on-deb is not enough for these four (and what is)

Syft-on-deb is a strong baseline but has a concrete, known blind spot for these packages:

- **Java jars** — Syft reads `pom.properties` inside jars (including nested jars in Spring
  Boot fat jars / WARs), so for most Maven-published dependencies a deb scan and a
  build-time SBOM produce nearly the same Java component list. Often a wash.
- **Bundled npm frontend** — the deb ships the *built* (minified/webpacked) UI with **no
  `package.json` / `node_modules`**, so Syft-on-deb sees essentially **no** frontend
  dependencies. This data exists only at build time (`package-lock.json`/`yarn.lock`).
  **This is the gap that justifies producing the SBOM with build context.**
- **Commercial/vendored jars** (DB2, Sybase) often lack `pom.properties` → Syft gets weak
  coordinates; the build (or a declared component) knows them exactly.

Counter-nuance: for **vuln scanning**, "deeper" is not automatically "more correct" — a
build-time dependency graph can include `provided`/test scopes that never ship in the deb,
producing false-positive CVEs. So the choice should be validated, not assumed.

### SBOM method for these four repos: Xray vs. Mend vs. per-language vs. Syft-on-deb

Two SCA tools are **already integrated** in the Delphix build and can export CycloneDX, so
neither is a new dependency — but they work differently, which matters here:

- **JFrog Xray** — self-hosted in-house (`xray.delphix.com`, Ansible role `dlpx.xray`),
  already wired into CI for **nearly every `linux-pkg` package plus the Docker and
  Hyperscale builds** (via `xrayScan()` in Artifactory), with native CycloneDX export.
  Xray **scans the uploaded `.deb` artifact itself**, so its SBOM corresponds to exactly
  that artifact.
- **Mend** — `.whitesource` configs in all four repos (a separate
  `apigw-services/client/.whitesource` covers the npm UI) plus `linux-pkg`'s
  `MEND_SCAN_APPLICABLE` / `MEND_SCAN_IMAGES` flags. Mend **resolves the source manifests**
  (Maven/Gradle, npm/yarn, Python) and scans container images; exports CycloneDX.

**Artifact-scan (Xray) vs. manifest-resolution (Mend)** is the key axis: Mend reads
declared dependencies from source (so it can see the bundled **npm frontend** — the gap
above), while Xray scans the compiled artifact (so it may share Syft-on-deb's blind spots
for bundled/minified npm and compiled Rust — to be checked in the diff).

This makes the source-repo SBOM a **four-way choice**, to be decided per the validation
diff (see Rollout):

1. **Xray export.** Reuse the existing Artifactory/Xray integration; export CycloneDX for
   the `.deb` Xray already scans. Least new work for `linux-pkg` packages, already covers
   the Docker/Hyperscale builds (relevant to the deferred DCT/Hyperscale work), and —
   because it scans the real artifact — the SBOM **matches the shipped `.deb` by
   construction** (no repo-state drift). Self-hosted, so it reaches an *internal* service,
   not the public internet.
2. **Mend export.** Configure Mend to export CycloneDX and publish it as the package's
   sidecar. Because Mend resolves manifests, it sees the npm frontend and other declared
   dependencies a compiled-artifact scan can miss — potentially a single producer across
   the four repos.
3. **Per-language build-time tooling.** The `cyclonedx-gradle-plugin` + `npm
   sbom`/`cyclonedx-npm` + `cyclonedx-python` + Syft-over-image-tarballs apparatus
   described per repo below. Use where the SCA-tool exports prove impractical.
4. **Syft-on-deb (baseline only).** Acceptable where a repo has no bundled frontend and no
   metadata-poor jars; insufficient on its own for these four because of the npm gap.

**Trade-off — vendor lock-in.** Options 1 and 2 rely on **commercial, paid** tools
(Xray, Mend); making SBOM generation depend on them deepens that lock-in and ties a
compliance/security deliverable to a licensed product. Options 3 and 4 use **open-source**
tooling (`cyclonedx-*`, Syft) and carry no such dependency. This should weigh in the
decision even when a paid tool is "already integrated and nearly free."

**Xray scope note.** Xray **cannot** scan the Delphix VM images (its indexer can't handle
our ZFS root — confirmed via a JFrog support case), so it is a *per-package producer*
candidate only, never the consumer's image-level base scan (that stays Syft-on-chroot).
Its other cost: an artifact must be in **Artifactory** to be scanned/exported — already
true for packages that `xrayScan` in CI, an added step otherwise.

**What to verify per tool (in the validation diff):**
- **Xray** — since it scans the *compiled* `.deb`, confirm whether it captures deep
  composition (bundled/minified **npm frontend**, **Rust crates**) or shares Syft-on-deb's
  blind spots; and that the export can be pulled for the exact shipped version.
- **Mend** — the **per-build/per-version drift** risk: its manifest scans run on
  PR/schedule against the repo's *latest* state, not the exact shipped `.deb`; needs a
  build-triggered export or a drift policy; plus scope hygiene (exclude non-shipped
  dev/test scopes).
- **Both** — container-image depth (in-container OS packages), exported CycloneDX spec
  version + PURL fidelity, and that the output is clean to publish as a customer artifact.

The per-repo notes below describe the **per-language** path (option 3); if an SCA-tool
export (option 1 or 2) is chosen, most of this per-repo build work is replaced by
configuring that tool's export.

### `masking` — `dms-core-gate`

- **Java/Gradle:** add `org.cyclonedx.bom` (cyclonedx-gradle-plugin) at the Gradle root
  (`build.gradle`, alongside the existing `com.github.jk1` plugin at lines ~40–41 /
  config ~190–231). It is multi-module-aware — one root task, no per-module edits — and
  emits CycloneDX with PURLs for all Java dependencies.
- **npm (new coverage):** the `packages/masking-ui`, `packages/swagger-ui`, and
  `packages/gql-adapter` Yarn-4 workspaces are **not** in today's report. Add an npm SBOM
  step (`npm sbom --format cyclonedx` or `cyclonedx-npm`) for them.
- **Vendored, non-Gradle JARs:** DB2/Sybase/font jars tracked in `lib/license_index.json`
  (via `buildSrc` `AddExternalLicenses.java`) are outside the dependency graph; declare
  them as explicit CycloneDX components so they aren't lost.
- **Merge + emit:** combine Java + npm + vendored into one `masking.cdx.json` from the
  `dist` build (`dist/build.gradle`, near `distLicenseReport` ~602–609 / `distDeb`
  ~667–723), placed where `linux-pkg/packages/masking/config.sh` can collect it.

### `virtualization` — `dlpx-app-gate`

- **Java/Gradle:** add cyclonedx-gradle-plugin to `appliance/build.gradle` (alongside the
  existing `com.github.jk1:gradle-license-report` at ~107, config ~134–178).
- **npm:** replace the `npm-license-crawler` pipeline with `npm sbom`/`cyclonedx-npm` for
  the `appliance/client` Angular frontends (`package-lock.json` present).
- **Vendored components:** fold `appliance/lib/license_index.json` and the
  `license_index_npm.json` files into the SBOM as declared components (replacing the
  `AddExternalLicenses.java` / `JsonReportImporter.java` merge for SBOM purposes).
- **Build topology:** the build is Ant-orchestrated, Gradle-driven for reports
  (`appliance/build.xml` `package` target ~303–317; configuration-on-demand is disabled
  there because the report needs full project evaluation). Wire SBOM generation +
  merge through `appliance/packaging/build.gradle` (near `distLicenseReport` ~53–61) into
  one `virtualization.cdx.json`, collected by
  `linux-pkg/packages/virtualization/config.sh` (~82–94).

### `dct` — `apigw-services` (built outside `linux-pkg`)

The shipped `delphix-dct` `.deb` bundles a Gradle/Java backend, an Angular/npm UI, Python
AI services, and **container images** (Alpine/OpenResty/Postgres-based). It already uses
the `com.github.jk1` license-report plugin. SBOM work:

- **Java:** add `cyclonedx-gradle-plugin` at the Gradle root.
- **npm:** add `npm sbom`/`cyclonedx-npm` for the `client` Yarn workspaces (UI + GraphQL).
- **Python:** `cyclonedx-python` for the AI/execution service dependencies.
- **Containers:** run **Syft** over each saved image tarball (covers the in-container OS +
  language layers) in the packaging step (`engine_packaging` / `save-images-to-tar`).
- **Merge + publish:** combine into one `delphix-dct.cdx.json` and publish it as a
  **sidecar in the same S3 artifact directory** the DCT build already populates (the one
  appliance-build syncs), included in that directory's `SHA256SUMS`.

### `delphix-hyperscale` — `hyperscale-masking` (built outside `linux-pkg`)

The shipped `delphix-hyperscale` `.deb` bundles a multi-module Gradle/Java application and
~12 **container images** (Java services + Postgres + OpenResty connectors). It already
uses the `com.github.jk1` license-report plugin. SBOM work:

- **Java:** add `cyclonedx-gradle-plugin` at the root (and/or per service).
- **Containers:** run **Syft** over each saved image tarball in `package_engine.sh`.
- **Merge + publish:** combine into one `delphix-hyperscale.cdx.json` and publish it as a
  **sidecar in the same S3 artifact directory** the hyperscale build already populates,
  included in `SHA256SUMS`.

For both, the merge produces a single per-package SBOM keyed to the installed
`delphix-dct` / `delphix-hyperscale` deb; appliance-build grafts it under that deb's
component (see the consumer flow). These two are the **priority** out-of-`linux-pkg`
candidates because their container-heavy payload makes the appliance-build deb-scan
fallback especially weak.

### Caveat: do not break the Debian copyright / notices pipeline

In both repos the license-report tasks **also** generate the Debian `copyright` file and
`THIRD-PARTY-NOTICES` text — a legal/packaging requirement distinct from the SBOM. The
migration must not break those. Recommended: **add** CycloneDX generation alongside the
existing license-report tasks (lowest risk; accepts some duplicate dependency
resolution), and only retire the legacy machinery later if the copyright/notices outputs
are re-derived from the CycloneDX. In other words, in these repos we *add* SBOM
generation rather than rip out the license-report code; what the new design supersedes is
`linux-pkg` copying `dependency-license/*` as the component record — replaced by the
`.cdx.json` sidecar.

Note this also decouples the BOM from the copyright files: today `generate_bom.py`
*parses* those embedded `copyright` files to build the BOM, which is the fragile coupling
we are removing. The `copyright` files stay (for their legal purpose); the BOM simply
stops being derived from them.

## Customer-facing BOM publishing

The BOM is a **customer deliverable**: today's product-publishing automation uploads the
per-platform CSV BOM to the Delphix download site alongside the product and upgrade
images. That automation must switch to uploading the CycloneDX document instead of the
CSV. The relevant pieces, all in `devops-gate`:

- **`jenkins/jobs/pipelines/appliance_build_stage0.groovy`** — generates the BOM
  (`generate_bom`/`combine_bom`) and `archiveArtifacts 'bom*.csv'`. This generation block
  is replaced: the per-image `<variant>-<platform>.cdx.json` now comes out of the
  appliance build itself (the new assembler), and the stage carries that into
  `build/metadata/` instead of running the Python BOM scripts.
- **`jenkins/jobs/pipelines/release_stage.groovy`** — stages the per-platform BOM into
  `Supplemental_Information/Licenses_and_BOMs/bom-<platform>.csv`. Update to stage the
  CycloneDX file (e.g. `Supplemental_Information/Licenses_and_BOMs/bom-<platform>.cdx.json`).
- **`jenkins/jobs/pipelines/release_publish.groovy`** — publishes the `bom-<platform>.csv`
  files with public permissions to the download site. Update the published file list
  (the `bom-*.csv` → `bom-*.cdx.json` entries and their `permissionsMap['public']`).
- **`jenkins/jobs/hyperscale_compliance_publish_artifacts_to_download_site.groovy`** —
  separately publishes a Hyperscale "BOM licenses file"; update it to publish the
  Hyperscale CycloneDX instead.

**Customer-facing format change — decide the transition.** Switching the published
artifact from CSV to CycloneDX JSON changes what customers (and any contractual/compliance
consumers) receive. Options: hard-switch (replace, per the directive), or **dual-publish**
both formats for a transition window and retire the CSV later. This is the externally
visible half of the *current CSV BOM consumers* open question, and the choice should be
confirmed with product/release stakeholders before cutover. Publishing CycloneDX is itself
a customer benefit — it is the industry-standard SBOM format their own scanners expect.

## Rollout / what it would take

1. **`linux-pkg` baseline:** add the `SBOM_DEEP_SCAN` flag (+ `query-packages.sh` field +
   CI lint), add `generate_sbom()` (Syft-on-deb, gated on the flag) to `lib/common.sh`,
   wire the sidecar into `store_build_info()`, and ensure S3 upload carries it. → a
   CycloneDX sidecar for each flagged 1st-party package (3rd-party forks are covered by the
   consumer's base scan).
2. **`linux-pkg` Rust override:** add `cargo-cyclonedx`/`Cargo.lock`-based generation
   for `zfs`, `ptools`, `delphix-rust`. → closes the Rust gap.
3. **Decide the source-repo SBOM method (validation diff):** for one representative repo
   (e.g. `masking`), generate the SBOM the candidate ways — Syft-on-deb, the per-language
   build-time tools, a **JFrog Xray** export (artifact scan), and a **Mend** export
   (manifest resolution) — and diff the component lists. This confirms, with evidence, what
   each method uniquely finds (expected: the bundled npm/frontend components appear in the
   per-language and Mend outputs, and may be absent from the artifact-scan outputs like
   Syft and Xray) and resolves the Xray-vs-Mend-vs-per-language-vs-Syft choice. Weigh the
   vendor lock-in of the paid tools (Xray, Mend) against their near-free integration, and
   verify the per-tool questions from *SBOM method for these four repos* (Xray: does the
   artifact scan reach the deep composition; Mend: per-build/per-version drift).
4. **First-party app SBOMs at source:** apply the chosen method (per *SBOM method for
   these four repos*) to `masking` (`dms-core-gate`), `virtualization` (`dlpx-app-gate`),
   `dct` (`apigw-services`), and `delphix-hyperscale` (`hyperscale-masking`) — Xray or Mend
   export if validated, else the per-language fallback (cyclonedx-gradle-plugin + npm/Python
   SBOM + Syft-over-image-tarballs) — and publish each as a sidecar. Plus any `linux-pkg` Go
   override (`cyclonedx-gomod`). Prioritize DCT/Hyperscale, since their container-heavy
   payload makes the appliance-build deb-scan fallback weakest.
5. **`appliance-build` consumer:** build the assembler — Syft base scan of the chroot
   (dpkg cataloger) → identify 1st-party components (COMPONENTS + `delphix-dct` /
   `delphix-hyperscale` by name) → merge in their source SBOMs (fallback: per-deb Syft
   scan) via `cyclonedx-cli merge`. This is the structured replacement for the
   `devops-gate` `generate_bom.py` / `combine_bom.py` scripts. Wire into
   `scripts/run-live-build.sh`, emit + upload `<variant>-<platform>.cdx.json`, add
   CycloneDX schema validation.
6. **Validate** end-to-end through a scanner, and confirm the new per-image CycloneDX
   covers everything the old CSV BOM did (diff component coverage against a current
   `generate_bom` run before cutover).
7. **Customer-facing publishing:** update the `devops-gate` publishing automation
   (`appliance_build_stage0.groovy`, `release_stage.groovy`, `release_publish.groovy`, and
   the Hyperscale download-site publish job) to upload the CycloneDX document to the
   download site instead of the CSV — after confirming the hard-switch vs. dual-publish
   transition with product/release stakeholders. See *Customer-facing BOM publishing*.
8. **Decommission the replaced parts** (only after the new path is validated and the
   publishing switch is in place):
   - `devops-gate`: remove `jenkins/scripts/generate_bom/` (`generate_bom.py`,
     `combine_bom.py`, `license_info.py`) and the pipeline step that invokes them.
   - `linux-pkg`: remove the `generateLicenseReport` copy steps from `masking` and
     `virtualization`, the `cargo-bundle-licenses` step from `zfs`, and the bespoke
     per-package `metadata.json` generation — once each is covered by its CycloneDX
     SBOM.
   - `appliance-build`: stop treating `.packages.list` as the inventory-of-record
     (after confirming the upgrade/verification dependency above — retain the file
     itself if upgrade needs it).
   - Leave `/var/delphix-buildinfo/` provenance, `COMPONENTS`, and the per-deb `copyright`
     files in place. Keep Mend scanning (and, if chosen, its new SBOM-export role).

## Limitations / open questions

- **Rust fidelity during transition:** until the Rust override (step 2) lands, Rust
  components appear as a `deb` with no crate-level children (baseline Syft-on-deb
  cannot see crates). Documented and accepted for the baseline increment.
- **License-field completeness** is best-effort. The driver is vuln-scanning, not a
  compliance deliverable, so license fidelity is not a gate; revisit if a compliance
  consumer is added.
- **Syft cataloger coverage:** confirm Syft's default catalogers cover the app
  frameworks present in 1st-party packages without extra configuration; tune per
  package where the override path is used.
- **deb → package SBOM association** for packages that emit multiple `.deb`s from one
  source build: one package-level SBOM is associated with all of that package's debs
  via `COMPONENTS`; verify this mapping holds for every 1st-party package.
- **Fallback `.deb` source in `appliance-build`:** confirm the canonical on-disk
  location of 1st-party `.deb`s at scan time (Aptly ancillary repo pool vs.
  `binary/packages`) for the fallback path.
- **Container SBOM depth (DCT/Hyperscale):** confirm how deep to inventory the bundled
  container images — for vuln scanning the in-container OS packages and language layers
  should be included (that is where most CVEs live), which produces many components.
  Decide whether each bundled image is a nested sub-component of the deb.
- **DCT/Hyperscale SBOM sidecar + SHA256SUMS:** the producer must add the `.cdx.json` to
  the artifact directory's `SHA256SUMS`, or appliance-build's checksum validation in
  `download_dct_artifacts()` / `download_hyperscale_artifacts()` will need adjusting.
- **Current CSV BOM consumers:** the known external consumer is the **download site**
  (customers), addressed by *Customer-facing BOM publishing*. Identify any other
  consumers (legal review, a release portal, support tooling). If one needs the CSV shape
  or the product classification (Virtualization / Masking / ZFS / Linux Package), provide
  a CycloneDX→CSV projection, or preserve the classification via CycloneDX component
  properties/`group`, before decommissioning the scripts. Resolving this also settles the
  hard-switch vs. dual-publish question for the download site.
