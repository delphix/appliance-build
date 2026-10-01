# SBOM Generation — merging package SBOMs into the per-image BOM (Phase 3)

- **Date:** 2026-10-01
- **Status:** Design (pending review)
- **Jira:** [DLPX-99410](https://perforce.atlassian.net/browse/DLPX-99410)
- **Epic:** [CP-13455](https://perforce.atlassian.net/browse/CP-13455) — CycloneDX SBOM for Delphix engine product images
- **Supersedes:** the earlier Phase 3 draft (`2026-09-15-sbom-appliance-build-merge-design.md`, filed under CP-13466), whose merge mechanism testing has since disproved — see *§2 Why `cyclonedx-cli merge` is not the mechanism*
- **Repos affected:** `appliance-build` only

## 1. What this does

Phase 1 (CP-13464, merged) scans the built rootfs with Syft's dpkg cataloger and emits
`<variant>-<platform>.cdx.json`: every installed `.deb` as one flat `pkg:deb` component.
That is correct for third-party packages, but a Delphix package appears as a single opaque
line:

```json
{
  "bom-ref": "pkg:deb/ubuntu/delphix-virtualization@2026.08.26.09?arch=amd64&distro=ubuntu-24.04&package-id=f7d2f85f",
  "type": "library",
  "name": "delphix-virtualization",
  "version": "2026.08.26.09",
  "purl": "pkg:deb/ubuntu/delphix-virtualization@2026.08.26.09?arch=amd64&distro=ubuntu-24.04"
}
```

Phase 2 (DLPX-98872) already produces a document describing what is *inside* that `.deb` —
421 components for `delphix-virtualization` — and publishes it to S3 beside the `.deb`.
Nothing reads it.

Phase 3 joins them: for each installed `.deb` that has a package SBOM, nest that SBOM's
components under the owning `pkg:deb` component. Packages with no SBOM stay flat, which is
the correct outcome for third-party packages and for anything not flagged
`SBOM_DEEP_SCAN="true"`.

Measured on real inputs (`internal-qa-aws` + the `virtualization` package SBOM):

```
before : 685 top-level components, delphix-virtualization has   0 children
after  : 685 top-level components, delphix-virtualization has 421 children
```

The top-level count is unchanged. Nothing is appended; components are *attributed*.

**Non-goals:** changing Phase 2's output; the `devops-gate` publishing switch; closing the
npm gap (CP-13467); DCT/Hyperscale producer-side SBOM generation.

## 2. Why `cyclonedx-cli merge` is not the mechanism

The earlier draft specified `cyclonedx-cli merge`. That was never verified, and testing
against a real image BOM shows it cannot do the attribution:

| mode | result |
|---|---|
| default (flat) | 685 + 421 = 1,103 top-level components. `delphix-virtualization` ends up with **0 nested components**; its jars sit loose in the top-level array, indistinguishable from OS packages |
| `--hierarchical` | nests by *input document*: two subtrees, `internal-qa-aws` (685) and `virtualization` (421). Requires `--name`/`--version`, and introduced a dangling ref |

Neither attributes a package's components to the `pkg:deb` that owns them, which is the
entire point of this phase. The attribution is therefore implemented directly (§5), and
`cyclonedx-cli` is used only for validation, as it is in Phases 1 and 2.

Worth recording: merging the *sanitized* package SBOM is strictly better than merging the
raw one either way — 1,103 vs 2,380 total components, and 0 vs 90 dangling refs — so Phase
2's sanitization is a prerequisite for a clean merge regardless of mechanism.

## 3. Inputs, and where they come from

**The package SBOMs arrive for free.** Phase 2 writes
`<deb-filename>.deb.cdx.json` into the same S3 directory as the `.deb`, and
`download_combined_packages_artifacts()` in `scripts/common.sh` does a directory sync:

```bash
retry aws s3 sync --only-show-errors "$s3uri" .
sha256sum -c --strict SHA256SUMS
```

So every package SBOM lands on the build host already, with no change to the download
logic. Crucially this does **not** require the package to have been rebuilt in this run —
appliance-build pulls prebuilt artifacts from `combined-packages`, and the SBOM travels
with the `.deb`.

**But they are deleted before they can be used.** `scripts/build-ancillary-repository.sh`
downloads into a `mktemp -d` and ends with `rm -rf "$WORK_DIRECTORY"`. That script runs
*once per build*, before any variant's `run-live-build.sh`. Without intervention the SBOMs
are gone by the time the merge would run. §4 addresses this.

**Packages built before Phase 2 landed have no SBOM at all.** Their S3 directories contain
a `.deb` and nothing else. This is a transitional state that resolves as packages are
rebuilt, and is handled by the "no SBOM → stay flat" rule (§6), not treated as an error.

## 4. Persisting the SBOMs

`build-ancillary-repository.sh` copies every `*.cdx.json` out of the temp directory before
deleting it, into a new directory alongside the existing ancillary-repository output:

```
live-build/build/
├── ancillary-repository/      (existing)
└── sboms/                     (new)
    ├── <deb-filename>.deb.cdx.json
    └── ...
```

Flat, not per-package: the filename alone carries everything the matcher needs (§5), and a
flat directory makes the lookup a single glob. This directory has the same lifetime as
`ancillary-repository/` — written once per build, read by every subsequent
`run-live-build.sh` invocation for each variant/platform.

## 5. Matching an SBOM to an installed `.deb`

**Match on the filename, not on the SBOM's metadata.** This is the subtle part.

The SBOM's `metadata.component.name` is the **linux-pkg package name**, not the `.deb`
name:

```
metadata.component: name=virtualization   version=2026.09.27.19   type=application
image BOM entry   : name=delphix-virtualization  version=2026.08.26.09
```

Those differ (`virtualization` vs `delphix-virtualization`), and one package can emit
several `.deb`s (`zfs` → `delphix-zfs`, …; `delphix-rust` → `delphix-rust` +
`delphix-rust-src`). Matching on `metadata.component` would be wrong in both directions.

The **filename** carries the `.deb` identity exactly. Phase 2 names each SBOM
`<deb-filename>.deb.cdx.json`, and a Debian filename is
`<package>_<version>_<arch>.deb`. Neither package names nor versions may contain `_`, so a
three-way split is unambiguous:

```python
def parse(fname):                       # delphix-virtualization_2026.09.27.19_amd64.deb.cdx.json
    base = fname[:-len('.cdx.json')]    # delphix-virtualization_2026.09.27.19_amd64.deb
    if not base.endswith('.deb'):
        return None
    name, version, arch = base[:-len('.deb')].split('_')
    return name, version.replace('%3a', ':'), arch   # ':' is %3a-encoded in filenames
```

Verified against real filenames, including a multi-`.deb` package, an `arch=all` package,
Delphix revision strings, and an epoch:

```
delphix-virtualization_2026.09.27.19_amd64.deb.cdx.json  -> (delphix-virtualization, 2026.09.27.19, amd64)
delphix-sso-app_2026.09.27.18_all.deb.cdx.json           -> (delphix-sso-app, 2026.09.27.18, all)
delphix-zfs_2.4.99-1delphix.2026.08.27.00.37_amd64...    -> (delphix-zfs, 2.4.99-1delphix.2026.08.27.00.37, amd64)
delphix-rust-src_1.89.0-1delphix.2026.09.15.06.40_...    -> (delphix-rust-src, 1.89.0-1delphix.2026.09.15.06.40, amd64)
libfoo_1%3a2.3-4_amd64.deb.cdx.json                      -> (libfoo, 1:2.3-4, amd64)
```

The corresponding key on the image-BOM side comes from the component's `name`, `version`
and the `arch` in its purl:

```
purl = pkg:deb/ubuntu/delphix-zfs@2.4.99-1delphix.2026.08.27.00.37?arch=amd64&distro=ubuntu-24.04
       ^name                      ^version                          ^arch
```

**Match on all three.** Name alone is not enough: if the installed `.deb` is from a
different build than the SBOM, the versions differ, and attributing the wrong build's
components would be worse than leaving the entry flat. A name match with a version
mismatch is a *warning*, not a match (§6).

Note `COMPONENTS` is not needed for this. The earlier draft used it to map a `.deb` to its
owning package; the filename makes that indirection unnecessary.

## 6. The merge

For each file in `live-build/build/sboms/`:

1. Parse the filename to `(name, version, arch)`. Unparseable → warn, skip.
2. Find the image BOM component with that `name`, `version` and purl `arch`. No match →
   skip silently: the package simply is not installed in this variant, which is normal
   (e.g. `containerized-masking` is in no appliance variant; DCT/Hyperscale only in their
   own variants).
3. Load the package SBOM. Nest its `components` array under the matched component's own
   `components` key.
4. After all files: re-validate with `cyclonedx-cli validate --input-version v1_6
   --fail-on-errors`.

Nesting — rather than appending flat and expressing ownership via `dependencies` edges —
because it is what the top-level design specifies ("each 1st-party deb is a `deb` component
with its bundled third-party components as **nested `components[]`**"), it is
self-describing without a second structure to consult, and it leaves the image BOM's own
dependency graph untouched (§8).

### Error handling

| condition | behaviour |
|---|---|
| `live-build/build/sboms/` missing or empty | Proceed with the Phase 1 document unchanged. Covers a build whose packages all predate Phase 2. Not an error. |
| SBOM present, matching `.deb` not installed | Skip silently. Expected for variant-specific packages. |
| `.deb` installed, no SBOM present | Leave it flat. Expected for third-party packages and for packages built before Phase 2. **Warn** only when the package is one we expect an SBOM for, if that list is available; otherwise silent. |
| name matches but version does not | **Warn**, do not attach. Indicates the image and the SBOM came from different builds. |
| SBOM present but unparseable JSON | **Fail the build.** A corrupt artifact is a data-integrity problem, not a coverage gap. |
| final `cyclonedx-cli validate` fails | **Fail the build.** Consistent with Phase 1 and Phase 2. |

The asymmetry is deliberate: *missing* data degrades gracefully, *corrupt* data fails
loudly. A producer-side hiccup in linux-pkg should not break every appliance build; a
malformed document that would ship to customers should.

## 7. Where it runs

In `scripts/run-live-build.sh`, after `lb build` succeeds and before the existing
artifact-move loop:

```bash
for ext in debs.tar.gz $vm_artifact_ext packages.list cdx.json; do
    if [[ -f "$ARTIFACT_NAME.$ext" ]]; then
        mv "$ARTIFACT_NAME.$ext" "$TOP/live-build/build/artifacts/"
    fi
done
```

At that point `$ARTIFACT_NAME.cdx.json` exists (written by the
`95-generate-sbom.binary` hook) and has not yet been moved, so the merge rewrites it in
place and the existing loop carries the enriched document onward unchanged. This is also
the integration point the top-level design named.

The merge logic itself lives in a new `scripts/merge-package-sboms.py` — Python rather than
`jq`, because the matcher needs filename parsing, purl field extraction and per-file error
handling, which are awkward in `jq` and readable in Python. It takes the image BOM path and
the SBOM directory as arguments, making it independently runnable against artifacts on disk
for testing, without a build.

No `devops-gate` change is required: Phase 3 produces the same filename at the same path,
and `appliance_build_stage0.groovy` already fetches and archives `*.cdx.json`.

## 8. What this must not change

**The image BOM's `dependencies` graph.** It is real and complete — 606 entries, 2,488
edges, zero dangling refs, 100% component coverage — derived from Debian `Depends:` fields
(`delphix-platform-aws` → 98 packages, `postgresql-14` → 23). Phase 2 rebuilt *its*
dependency graph because Syft's version there covered 30% of components and held 90
dangling refs; that reasoning does not transfer. Nesting components changes no `bom-ref`,
so the graph stays valid untouched.

**The 685 top-level entries.** Components are nested, not appended. A consumer that ignores
nesting sees exactly the document it sees today.

**Phase 2's output.** Phase 3 is a pure consumer.

## 9. Open items

- **`compositions` propagation.** Phase 2's SBOMs carry `compositions: [{aggregate:
  "incomplete"}]`. Nesting their components does not import that element, but the merged
  document arguably *is* now partly incomplete. Whether to declare that at image level
  needs deciding — it should be deliberate, not inherited by accident.
- **Root component type.** The image BOM's `metadata.component.type` is `file`; Mend
  support flagged this, but neither a `file`-rooted nor an `application`-rooted scan showed
  an observable difference in testing. Tracked as DLPX-99414 and currently **on hold**
  pending Mend's answer. Whatever is decided applies to the merged document, since it
  inherits the image BOM's root.
- **Package SBOMs for `.deb`s not in `COMPONENTS`.** DCT and Hyperscale are downloaded by
  `download_dct_artifacts()` / `download_hyperscale_artifacts()` into the same work
  directory, so their SBOMs would be persisted and matched by the same filename rule *if
  their builds ever produce them*. No producer does today; this needs no special handling,
  and will start working when those producers exist.

## 10. Verification

- A real appliance build for a variant installing at least one flagged package; confirm the
  owning `pkg:deb` entry gains nested components and the document still validates.
- A variant installing none of the flagged packages; confirm the output is identical to the
  Phase 1 document.
- `dependencies` still reports 606 entries / 2,488 edges / 0 dangling / 100% coverage —
  i.e. demonstrably untouched.
- Grype and Mend scans of the merged document, compared against the unmerged one, to
  establish whether the nested components are actually ingested by each. This is worth
  measuring rather than assuming: Grype and Mend were shown during Phase 2 to find
  disjoint vulnerability sets, and Mend skips `type: application` components entirely.
- The merge script run standalone against two files on disk, as a fast feedback loop that
  does not require a build.
