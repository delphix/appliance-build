# SBOM Generation — is Syft-on-deb enough for virtualization and masking? (Phase 4)

- **Date:** 2026-10-26
- **Status:** Evaluation (pending review)
- **Jira:** [DLPX-100120](https://perforce.atlassian.net/browse/DLPX-100120) (formerly CP-13467)
- **Epic:** [CP-13455](https://perforce.atlassian.net/browse/CP-13455) — CycloneDX SBOM for Delphix engine product images
- **Repos affected:** `linux-pkg`, `dlpx-app-gate`

## 1. Question and answer

The CycloneDX SBOM is to replace the CSV BOM (`bom-<variant>.csv`) published today
(CP-13468). Before it can, it must list everything the CSV lists for the two packages with
the most bundled third-party code, `delphix-virtualization` and `delphix-masking`, or
explain each difference.

| Package | Decision | Change needed |
|---|---|---|
| `delphix-masking` | **Syft on the `.deb` is sufficient** | none |
| `delphix-virtualization` | **Syft on the `.deb`, plus the UI's npm lock files and a list of copied libraries generated from the repository's `*.DESC.json` files, shipped in the `.deb`** | `dlpx-app-gate` ships 4 `package.json`/`yarn.lock` pairs and `vendored-components.cdx.json`; `linux-pkg` catalogs them |

Neither package needs per-language build-time tooling, a JFrog Xray export or a Mend export
(§6).

## 2. How the comparison was made

Inputs are the artifacts of stage0 pre-push #13252 (`internal-qa-aws`; `external-standard-aws`
gives the same numbers, bar one masking row):

- the CSV, `bom-internal-qa-aws.csv`, rows for the products `Virtualization` and `Masking`;
- the package SBOMs linux-pkg published beside each `.deb`.

The CSV's `Virtualization` product is everything built from `dlpx-app-gate`, which includes
`delphix-sso-app`, so it is compared with the virtualization and sso-app SBOMs together.
Comparing it with virtualization alone counts 44 Spring Boot, OpenSAML and Shibboleth jars
as missing that are in fact listed, under sso-app.

Components are matched by name: the CSV has no group IDs or purls, and writes npm scopes
without the `@` (`angular/material`). Every name found in only one of the two was then
looked for in the extracted `.deb` itself.

## 3. Masking

| | CSV | SBOM |
|---|---|---|
| distinct names | 349 | 727 |
| in both | 344 | 344 |
| only in this one | 5 | 383 |

The 5 names only in the CSV:

| Name | Why |
|---|---|
| `tomcat-catalina` 11.0.26 | Listed, as `catalina` 11.0.26 |
| `azure-sdk-bom`, `hibernate-platform` | Maven BOM POMs: version constraints, no shipped code |
| `knockout-kendo` 0.10.0 | Not shipped. Named only in `WEB-INF/lib/license_index.json` and the copyright file |
| `Bitstream-VeraFonts` 1.10 | Not shipped, as above |

The SBOM's 383 extra names are Maven jars the CSV never listed and 66 Python wheels of the
classifier. Where both list a component at different versions, the SBOM has the version that
ships: the CSV says `azure-json` 1.2.0 and `azure-xml` 1.1.0, the jars in the `.deb` are 1.5.1
and 1.2.1.

## 4. Virtualization

### 4.1 Before

| | CSV | SBOM (virtualization + sso-app) |
|---|---|---|
| distinct names | 463 | 429 |
| in both | 330 | 330 |
| only in this one | 133 | 99 |

| Names only in the CSV | Count | Why |
|---|---|---|
| npm libraries compiled into the UI bundles | 103 | **The gap** (§4.2) |
| npm build/test tools and typings (grunt-\*, jasmine, karma, listr, `@types/*`) | 12 | Not shipped, except jasmine and karma-jasmine-old (§4.5) |
| `spring-boot-starter-*` | 7 | Not shipped: `sso-app.jar`'s 84 `BOOT-INF/lib` jars include none |
| Maven BOM POMs | 4 | No shipped code |
| Same component under another name (okhttp/okhttp-jvm, okio/okio-jvm, jconnect/jconn4, org.jacoco.agent/org.jacoco.agent.rt) | 4 | Listed |
| jacl, javax.inject, easymock | 3 | §4.4, §4.5 |

### 4.2 Why the UI's npm libraries are missing

The UIs ship in `ROOT.war` (webpack bundles of `client` and `webapp`), `setup.war` and
`server-setup.war` (Angular CLI builds), as minified JavaScript. Nothing in a bundle that
Syft reads names the packages compiled into it, and no lock file ships.

Separately, Syft's default cataloger set for a directory scan, which is how linux-pkg scans an
extracted `.deb`, leaves out `javascript-package-cataloger`: installed `node_modules`
packages are listed only for an image scan. The 34 packages virtualization's CLI ships under
`opt/delphix/client/lib/node_modules` were not listed either.

The CSV gets its npm rows from `npm-license-crawler --onlyDirectDependencies`, run over every
`package.json` in the repository without `--production`, plus two hand-maintained
`license_index_npm.json` files. It lists direct dependencies only, development ones included;
the transitive runtime dependencies compiled into the bundles are not in it.

### 4.3 Shipping the lock files, and the catch

Shipping each UI project's lock file in the `.deb`, so that Syft catalogs it, was the
suggested fix. The four projects use yarn v1 lock files, which record every dependency,
runtime and development alike; Syft tells them apart by reading the `package.json` beside the
lock file. Measured with Syft 1.46.0, the version the build uses:

| Project | All lock entries | Runtime only (lock file at the scan root) |
|---|---|---|
| webapp | 1,847 | 445 |
| setup | 1,539 | 388 |
| server-setup | 1,541 | 391 |
| client | 2,577 | 753 |

Syft applies that filter only when the lock file is at the root of the scan. A lock file one
directory down, as any lock file in a `.deb` is, gives every entry whatever
`include-dev-dependencies` is set to: shipped as it is, the SBOM would list about 7,500 npm
components, mostly the build toolchain.

So linux-pkg scans each shipped lock file's directory on its own, where the filter works, and
hands the result to the main scan as an embedded CycloneDX document, which Syft's
`sbom-cataloger` merges in. A lock file records no licenses, so that scan looks them up in
Artifactory's `dlpx-npm` registry, through which the UI builds already resolve.

The lock files the `.deb` ships are copied after the UI builds have run `yarn install`, not
taken from the repository as committed. yarn rewrites a lock file whose entries no longer
match the packages, which happens for `client`'s `file:` dependencies on packages built
earlier in the same build (`@dlpx/dxDataSystem`, the `webapp/dist` libraries). The committed
`client/yarn.lock` still records an old `@dlpx/dxDataSystem` that depended on knockout 3.1.0,
backbone 1.2.3 and blueimp-file-upload. The shipped one records what is actually built in:
all four shipped lock files differ from the committed ones (`client` by 518 lines).

### 4.4 After

The CSV of #13252 compared with the package SBOMs built with both changes, by pre-push
#15643 (virtualization package build #2527, on develop as of 2026-10-26) and #13252
(sso-app):

| | Before (#13252) | After (#15643) |
|---|---|---|
| virtualization components | 415 | 1,257 |
| npm components (with a license) | 0 | 841 (806) |
| CSV names not in the SBOM (virtualization + sso-app) | 133 | 23 |

The SBOM's numbers above include the seven components of `vendored-components.cdx.json`
(§4.5), and are those of pre-push #15738 (virtualization package build #2550), the last build
of the change: it generates that list from the `*.DESC.json` files and checks each version
against the shipped code. The 23 left:

| Names | Count | Status |
|---|---|---|
| `spring-boot-starter-*` | 7 | Not shipped |
| Maven BOM POMs | 4 | No shipped code |
| grunt-angular-templates, npm-license-crawler | 2 | Build tools, not shipped |
| knockout-test 3.5.1, easymock 5.6.0 | 2 | Test libraries, not shipped |
| jackson-dataformat-toml 2.22.3 | 1 | No longer shipped: it came with Flyway 9, and develop has moved to Flyway 11 |
| okhttp, okio, jconnect, org.jacoco.agent, knockout, highstock-custom, karma-jasmine-old | 7 | Listed under another name, at the CSV's version (`@dlpx/knockout`, `@dlpx/highstock-custom`, and `karma-jasmine`, which `karma-jasmine-old` is a renamed copy of) |

"Not shipped" was checked against the file list of the `.deb` and of every `.war` in it.

The comparison uses the per-variant CSV, `bom-internal-qa-aws.csv`. `bom.csv`, the CSV before
the Ubuntu packages are added, has one more Virtualization row: `less` 3.9.0. The per-variant
CSVs lose it, apparently because the Ubuntu pager package is also named `less`. It is less.js,
a copy in `dxcore.war`, and was in no SBOM; it is now one of the components of §4.5. Against
`bom.csv` (464 names), the CSV-only names are the same 23.

Of the 133 names previously missing, 107 are now listed as npm components, 77 of them at the
CSV's version; the others are at the version the lock file resolved, which is the one built
into the bundle.

The same check over every jar in the `.deb`: Syft identifies 1,185 of 1,227. The other 42 are
the 4 jacl 1.4.1 jars (jacl, janino, tcljava, tjc), 3 copies of `javax.inject-1.jar` and 35
Delphix jars in `tools/bundle-redact/lib`, which the CSV does not list either. None of these
jars has a `META-INF/MANIFEST.MF` or `pom.properties`, which is what Syft identifies a jar by.

### 4.5 What no scan can see

Seven components that ship and that the CSV lists cannot be identified from the `.deb`:

| Component | Where | Why |
|---|---|---|
| jacl 1.4.1 | `host/unix/bin/expect/libs/jacl/` | Jars without Maven metadata |
| javax.inject 1 | the flyway-migrate, tomcat-launcher and bundle-redact libraries | Jar without Maven metadata, brought in by password-vault-manager through caffeine's jcache |
| handlebars 4.7.8 | `dxcore.war`, `lib/handlebars` | A copy kept in the repository (the CSV's 4.7.7 is out of date) |
| jasmine 1.3.1 | `dxcore.war`, `lib/jasmine` | A copy kept in the repository |
| karma-jasmine 0.1.6 | `dxcore.war`, `lib/karma-jasmine-old` | A renamed copy kept in the repository |
| highlight.js 9.2.0 | `dxcore.war`, `lib/highlight` | A copy of its stylesheet kept in the repository |
| less.js 3.9.0 | `dxcore.war`, `lib/lessjs` | A copy kept in the repository; listed only in `bom.csv` (§4.4) |

The repository keeps a `*.DESC.json` descriptor (name, version, license) beside each piece
of third-party code. Each of the seven now has one with a `purl` field: the four existing
descriptors gained the field, and karma-jasmine-old, less.js and javax.inject (in
`server/core`, which declares password-vault-manager) got new ones. The repository's schema
for descriptors, `tools/3rdparty-bom/json_schema.json`, checked by
`ThirdPartyBOMJSONSchemaTest`, now allows and validates the two new fields. When the package is built,
`appliance/packaging/sbom/generate-vendored-sbom.py` writes a CycloneDX document listing
every descriptor that has a `purl`, shipped as
`/opt/delphix/server/share/sbom/vendored-components.cdx.json`. Syft's `sbom-cataloger` merges
it into the package SBOM as it does the lock files' results.

The script fails the build if a `purl` is malformed, disagrees with the descriptor's
version, is listed twice, or if no descriptor has one. It also checks each descriptor against
the code it describes, so that updating the code without the descriptor fails the build rather
than leaving a stale version in the SBOM. A descriptor with a `purl` must say, in a
`version_in` field, where that version can be read:

| Component | `version_in` |
|---|---|
| jacl, javax.inject | the jar names in the package being built (`jacl-*.jar`, `javax.inject-*.jar`). The check also fails if the jar is gone, or ships at more than one version |
| handlebars | the `handlebars v4.7.8` header of `handlebars.js` |
| jasmine | the `major`, `minor` and `build` fields in `jasmine.js` |
| karma-jasmine | the `version` in the copy's `package.json` |
| less.js | the `Less - Leaner CSS v3.9.0` header of `less.js` |
| highlight.js | `unchecked`: only a stylesheet is kept, and it records no version |

`jaclVer` and `passwordVaultManagerVer` in `gradle.properties` carry a comment pointing at the
descriptors.

Other ways were tried and do not work: Syft 1.46 finds nothing in the jacl and javax.inject
jars even with `--enrich java` or network lookups enabled, and does not look for npm
metadata inside a `.war`, so the four JavaScript copies cannot be fixed by shipping a
`package.json` with them in `dxcore.war`.

### 4.6 Other packages

The linux-pkg change applies to every package with `SBOM_DEEP_SCAN="true"`. Rescanning all
32 such `.deb`s of #13252 with it: virtualization changes as above; `delphix-rust-src` gains 2
components, the root projects of two `package-lock.json` files in Rust's vendored sources; the
other 30 are unchanged, masking and sso-app included.

## 5. Changes

- **dlpx-app-gate** (`appliance/packaging/debian/rules`): ship `client`, `webapp`, `setup`
  and `server-setup`'s `package.json` and `yarn.lock` under
  `/opt/delphix/server/share/npm-manifests/<project>/`, and
  `vendored-components.cdx.json`, generated from `*.DESC.json` files (§4.5), under
  `/opt/delphix/server/share/sbom/`.
- **linux-pkg** (`lib/common.sh`): `catalog_npm_lockfiles()` as in §4.3, and
  `--select-catalogers +javascript-package-cataloger,+sbom-cataloger` on the main scan.
  The registry is `SBOM_NPM_REGISTRY`; an unreachable one leaves the components listed
  without licenses rather than failing the build. In #15643 the whole SBOM step of the
  virtualization build, license lookups included, took 111 seconds.

## 6. The other candidates

The ticket names four methods. Only the first was needed:

- **Syft on the `.deb`** — chosen, with the two changes above. It describes what ships, by
  construction.
- **Per-language build-time tooling** (cyclonedx-gradle-plugin, cyclonedx-npm). The Java side
  is already complete from the `.deb`, so the gradle plugin would add nothing. For npm it would
  at best produce what the lock-file scan now produces, as a new tool in four project builds
  that use yarn v1; not measured.
- **JFrog Xray export.** Xray scans the uploaded `.deb`, the same artifact Syft scans, so it
  is expected to share Syft's blind spot for minified bundles; not measured. It is also a paid
  tool, and it cannot scan the VM images.
- **Mend export.** Mend resolves the repositories' manifests, so it sees the npm frontend, but
  it scans the repository's latest state rather than the shipped `.deb`, and it is a paid tool;
  not measured.

## 7. Open

1. **Other copies kept in the repository**
   ([DLPX-100126](https://perforce.atlassian.net/browse/DLPX-100126)). Third-party code that
   ships in the `.deb` but is in neither the CSV nor the SBOM, and needs a `purl` and a
   `version_in`:
   - with a descriptor already: jqTree, jquery.smooth-scroll 1.4.13 (a copy older than the
     npm 2.2.0 the SBOM lists), jasmine-jquery 1.5.2, rsync, PostgreSQL xlogdump (shipped
     for 9.0.9, 9.1.9 and 9.2.4), inih and jsmn (compiled into the PAM modules), and the
     Open Sans and Roboto fonts;
   - without one: angular-mocks 1.9.11, angular-i18n and the Glyphicons Halflings fonts,
     copies in `client/dxcore/lib`.

   Several of these record no version, which has to be found first. bash and jq need
   nothing: Syft identifies their host binaries.
2. **javax.inject.** Replacing `javax.inject:1` with `jakarta.inject-api:1.0.5`, which has
   the same `javax.inject` API and Maven metadata, would let Syft find it and remove its
   descriptor. That changes what Flyway and Tomcat load, so it is left to its own change.
