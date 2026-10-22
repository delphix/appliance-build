# Building an image and getting it onto a test VM

`appliance-build` produces VM images — it has no running product of its own to redeploy a change
onto, unlike a product repo such as `dlpx-app-gate`. "Deploying a change" here means building an
image that includes the change, then booting it.

## Local build + boot verification

From a build VM (see the root [`README.md`](../../README.md)'s own Quickstart for provisioning
one, e.g. `dc clone-latest --size COMPUTE_LARGE dlpx-internal-buildserver-develop $USER-bootstrap`,
or the fuller `bootstrap-20-04` DCenter-on-AWS flow also documented there), with this repo checked
out and `ansible-playbook bootstrap/playbook.yml` already run once to configure the host, build for
**`Kvm`** specifically — `live-build/build.gradle`'s own `artifactTypes` map only produces a
`.qcow2` artifact (the format `qemu` below expects) for `kvm`/`oci`, so any other `<Platform>`
(`Aws`, `Azure`, `Esx`, `Gcp`, `Hyperv`) leaves no file at the path the boot check below reads:

```bash
sudo JAVA_HOME=<path to a Java 8 JDK> \
  DELPHIX_PACKAGE_MIRROR_MAIN=<mirror URL> DELPHIX_PACKAGE_MIRROR_SECONDARY=<mirror URL> \
  ./gradlew build<Variant>Kvm   # e.g. buildInternalMinimalKvm
```

Pass `JAVA_HOME`/the mirror URLs this way (`sudo VAR=value ...`, the same pattern this repo's own
root `README.md` already uses for `DELPHIX_PLATFORMS`) rather than exporting them first — plain
`sudo` resets the environment, dropping both: `scripts/run-live-build.sh` hard-requires
`DELPHIX_PACKAGE_MIRROR_MAIN`/`DELPHIX_PACKAGE_MIRROR_SECONDARY` (`check_env` fails the build
without them), and a `JAVA_HOME` left at the host default (17, per `bootstrap`) fails the Gradle
5.1 wrapper before the build starts.

The build reads S3 for the Secure Boot signing keys
([`live-build/config/hooks/vm-artifacts/90-raw-disk-image.binary`](../../live-build/config/hooks/vm-artifacts/90-raw-disk-image.binary))
and for the linux-pkg artifacts ([`scripts/common.sh`](../../scripts/common.sh),
[`scripts/fetch-livebuild-artifacts.sh`](../../scripts/fetch-livebuild-artifacts.sh)), so the build
host needs AWS credentials that can read those buckets. Jenkins binds them for its own builds; for
a build by hand, put them in the environment `sudo -E` carries through, the same way `JAVA_HOME`
and the mirror URLs are passed above. The images themselves carry no credential.

This produces `live-build/build/artifacts/<variant>-kvm.qcow2` (among other artifacts). For a
quick, minimal boot-verification that the change doesn't break the build or an obvious boot path:

```bash
sudo qemu-system-x86_64 -nographic -m 1G \
  -drive file=live-build/build/artifacts/<variant>-kvm.qcow2
```

Log in via the console with `delphix`/`delphix` once it boots — this default login is for the
local `qemu` image above only, not any other VM this doc set references (e.g. a DCenter-
provisioned engine, which has its own separate credentials). `Ctrl-A X` exits `qemu`. This is a
local sanity check, not a substitute for the real CI orchestrator build (see
[`ci-runs.md`](ci-runs.md)) or a QA-run engine.

## What this doesn't cover: upgrade testing

Building and booting a `Kvm` QCOW2 as above never exercises `upgrade/upgrade-scripts` or
`upgrade/prepare` — those only run during an actual upgrade, not a fresh boot. To build and test
an upgrade: build an upgrade image with `buildUpgradeImage<Variant>` (see the root
[`README.md`](../../README.md)'s own "Building an Upgrade Image" section for the exact command
and the resulting tarball's location under `build/artifacts/`), apply it to a disposable
appliance, then see
[`upgrade/upgrade-scripts/tests/README.md`](../../upgrade/upgrade-scripts/tests/README.md) for the
`upgrade-container` regression test flow that exercises these scripts directly.

## Getting a CI-built image onto a real VM

Both the automatic per-PR orchestrator check and a manual `git ab-pre-push` run (see
[`ci-runs.md`](ci-runs.md)) build real images and register them into DCenter. To get one onto a
real, clonable VM rather than a local `qemu` boot:

1. Find the orchestrator build's own `<cloud>-snapshots` sub-jobs in its Jenkins console/build
   tree.
2. Each of those leads to a `sync-image-into-dcoa` job; read its own console for the
   `dc image add-group <CLOUD> <image-id> <group>` line — that names the DCenter group the image
   landed in.
3. Verify the image is actually there: `dc list-snaps <group>`.
4. Clone it: `dc clone-latest <group> <new-instance-name>` brings up a real VM running whatever is
   newest in the group; `dc clone <group> <new-instance-name> -s <snapshot>` clones a specific,
   named snapshot instead of the newest one.
