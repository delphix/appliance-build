# Syft / cyclonedx-cli Build-Host Provisioning — Design

- **Companion to:** `docs/specs/2026-06-15-sbom-generation-design.md` (CP-13456)
- **Epic:** [CP-13455](https://perforce.atlassian.net/browse/CP-13455) — CycloneDX SBOM for Delphix engine product images
- **Follows up on:** review feedback from [PR #892](https://github.com/delphix/appliance-build/pull/892) (CP-13464), [comment](https://github.com/delphix/appliance-build/pull/892#discussion_r3769010612)

## Problem

CP-13464 (PR #892) provisions `syft` and `cyclonedx-cli` on the appliance-build host by
downloading pinned, checksum-verified releases directly from `github.com` in
`bootstrap/roles/appliance-build.bootstrap/tasks/main.yml`, at build time.

Review feedback flagged this as against convention:

> We generally discourage installing build dependencies from the public Internet at runtime.
> This introduces instabilities in our builds. Separately, it feels like hard-coding versions
> in here is an anti-pattern (this becomes immediate tech-debt).

(Mirroring the tools into Delphix's internal apt mirror was also considered, but ruled out —
neither `syft` nor `cyclonedx-cli` publishes an apt repo upstream, so there's nothing to mirror.)

## Proposed design: package via `linux-pkg`

`linux-pkg` already has a well-trodden pattern for exactly this case — packaging a
pre-built, upstream-published third-party binary as a first-party `.deb`, fetched from
Delphix's own Artifactory rather than the public internet at build time:

| Package | Repo | Fetch script | Fetches from |
|---|---|---|---|
| `delphix-go` | [`github.com/delphix/delphix-go`](https://github.com/delphix/delphix-go) (`develop`) | `scripts/fetch-and-run-installer.sh` | `artifactory.delphix.com/artifactory/linux-pkg/go` |
| `host-jdks` | [`github.com/delphix/host-jdks`](https://github.com/delphix/host-jdks) (`develop`) | `scripts/fetch-file-from-artifactory.sh` | `artifactory.delphix.com/artifactory/delphix-java-packages`, sha256-verified |

`linux-pkg/packages/<name>/config.sh` is a two-line shim for both — it just points
`DEFAULT_PACKAGE_GIT_URL` at the dedicated packaging repo; the fetch script, `debian/rules`,
and checksum verification all live in that separate repo, not in `linux-pkg` itself.

**Proposed for `syft` and `cyclonedx-cli`:** two new dedicated repos (or one shared repo, à la
`misc-debs`), each with a `debian/` directory and a fetch-and-checksum script pointed at a new
Artifactory path (e.g. `artifactory.delphix.com/artifactory/linux-pkg/syft`,
`.../linux-pkg/cyclonedx-cli`), packaged as `.deb`s the same way as `delphix-go`/`host-jdks`.
Fetch the pre-built release binary for both — do not build either from source. (No `.NET`
toolchain precedent exists in `linux-pkg` for `cyclonedx-cli`, and `syft`'s Go toolchain
precedent via `delphix-go` is unnecessary when the official binary is already available.)

Once packaged, publishing and consumption follow the existing, unmodified pipeline every
other first-party package uses: `linux-pkg` build → `combine-packages` → S3 manifest →
`appliance_build_stage0.groovy`'s `AWS_S3_URI_COMBINED_PACKAGES` flow. No new plumbing.

## Architecture diagram

```
+---------------------------------------------------------------------------+
| Upstream: github.com/anchore/syft, github.com/CycloneDX/cyclonedx-cli     |
|   (official pre-built release binaries)                                   |
+---------------------------------------------------------------------------+
                                     |
                                     |  one-time seed (per version bump)
                                     v
+---------------------------------------------------------------------------+
| artifactory.delphix.com/artifactory/linux-pkg/{syft,cyclonedx-cli}        |
+---------------------------------------------------------------------------+
                                     |
                                     |  fetched + checksum-verified
                                     v
+---------------------------------------------------------------------------+
| linux-pkg  --  PRODUCER                                                   |
|   packages/syft, packages/cyclonedx-cli  (delphix-go/host-jdks pattern)   |
|   build() --> .deb                                                        |
|   listed in package-lists/build/main.pkgs                                 |
|   NEVER referenced by any appliance-build chroot package list             |
+---------------------------------------------------------------------------+
                                     |
                                     |  combine-packages -> S3 manifest
                                     v
+---------------------------------------------------------------------------+
| appliance-build  --  CONSUMER                                             |
|   bootstrap/roles/appliance-build.bootstrap  (ephemeral build VM)         |
|     fetch .deb, apt install onto the build host                           |
|                                                                           |
|   syft / cyclonedx-cli now on PATH for run-live-build.sh                  |
|   (used to scan + validate the image -- never installed INTO it)          |
+---------------------------------------------------------------------------+
                                     |
                                     |  scans, but never writes into
                                     v
+---------------------------------------------------------------------------+
| live-build/build/<variant>-<platform>/binary/  (shipped rootfs)           |
| syft / cyclonedx-cli are absent from this tree, by design                 |
+---------------------------------------------------------------------------+
```

## Critical constraint: build-host tooling, never shipped in the image

Per the original design spec's Tooling section, Syft must be "installed on the build host in
both repos — never inside the shipped image." Being listed in `linux-pkg/package-lists/build/main.pkgs`
does **not**, by itself, put a package inside the shipped appliance — that only happens if an
appliance-build chroot package list (`live-build/config/package-lists/*.list.chroot*`, or a
variant's own list) names it. Confirmed with `delphix-go` as a live example: it's built by
`linux-pkg` and listed in `main.pkgs`, but it appears in **zero** appliance-build chroot lists
today — it's a build-only toolchain package, invisible to `syft scan dir:binary`.

`syft`/`cyclonedx-cli` must follow the same rule: add to `linux-pkg`'s `main.pkgs`, **never**
to any appliance-build chroot list. `bootstrap/roles/appliance-build.bootstrap/tasks/main.yml`
fetches the resulting `.deb` and installs it onto the ephemeral build VM directly — replacing
today's `get_url` + `apt: deb:` tasks that hit `github.com`, with the same tasks pointed at
the internal package instead. This is worth an explicit comment in the new packages' configs,
since `main.pkgs`'s own README describes it as "packages... added to the Delphix Appliance,"
which invites the (wrong) assumption that being listed there ships it in the image.

## Open question — Artifactory seeding

`delphix-go`/`host-jdks`'s fetch scripts assume the real upstream artifact already exists at
their Artifactory path — something/someone puts it there before the package can build. No
documented process for this was found in `devops-gate/artifactory/docs/`. Before this design
can be implemented, we need to confirm the correct way to seed
`artifactory.delphix.com/artifactory/linux-pkg/syft` (and the `cyclonedx-cli` equivalent)
with the initial release binaries, and how that gets refreshed on a version bump.

## Relationship to PR #892

PR #892's `run-live-build.sh`/`build.gradle` changes (the actual Syft scan + CycloneDX
validation) are unaffected by this design — only the *provisioning* mechanism
(`bootstrap/roles/appliance-build.bootstrap/tasks/main.yml`) changes. The GitHub-fetch
ansible tasks added there are treated as an interim implementation, to be replaced by the
`linux-pkg`-sourced install once this design is implemented.

## Rollout

1. Confirm the Artifactory-seeding process (open question above).
2. Create the packaging repo(s) for `syft` and `cyclonedx-cli` (`debian/` + fetch script,
   modeled on `host-jdks`).
3. Add `packages/syft/config.sh` and `packages/cyclonedx-cli/config.sh` to `linux-pkg`,
   add both to `package-lists/build/main.pkgs` — **not** to any appliance-build chroot list.
4. Update `bootstrap/roles/appliance-build.bootstrap/tasks/main.yml` (PR #892) to install the
   resulting `.deb`s from the internal package flow instead of `github.com`.

## Limitations / open questions

- Artifactory seeding process (above) — blocks implementation until resolved.
- Version bump cadence: `delphix-go`/`host-jdks` take an explicit version argument per fetch;
  the same explicit-pin approach (no `:latest`) should carry over here.
- Whether `syft`/`cyclonedx-cli` warrant one shared packaging repo or two — no strong
  precedent either way (`delphix-go`/`host-jdks` are each single-purpose, single-tool repos).