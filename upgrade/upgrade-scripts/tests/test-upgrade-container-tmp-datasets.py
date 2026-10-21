#!/usr/bin/env python3
#
# Tests the /tmp and /var/tmp datasets an upgrade container is built with.
#
# An engine built to be CIS compliant carries /tmp and /var/tmp as
# separate ZFS filesystems, mounted nosuid,nodev. upgrade-container's
# contract is that a container cloned from such a boot environment gets
# the same two filesystems and an fstab that mounts them, so that a boot
# environment made out of that container is CIS compliant too, and that a
# container cloned from a boot environment without them does not get them.
#
# The tests run the real script against a stand-in for zfs(8) that holds
# its inventory in a JSON file (upgrade-container-stubs/), so they need no
# appliance and no pool. The script does require root, and writes to
# /var/lib/machines and /etc/systemd, so the test runs itself in a user
# and mount namespace with a scratch directory bound over each of those.
# On hosts that restrict unprivileged user namespaces, run it as root
# instead.
#
#   ./test-upgrade-container-tmp-datasets.py
#
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from typing import Any, Dict, List

TESTS_DIR = os.path.dirname(os.path.realpath(__file__))
STUBS_DIR = os.path.join(TESTS_DIR, "upgrade-container-stubs")
SCRIPT = os.path.join(TESTS_DIR, os.pardir, "upgrade-container")

BOOT_ENVIRONMENT = "rpool/ROOT/delphix.oiknl78"
VERSION = "2026.6.0.0"

#
# The directories the script writes to by absolute path. Each is bound to
# a directory under the test's own scratch space for the duration of a
# test.
#
SANDBOXED = ["/var/lib/machines", "/etc/systemd", "/var/tmp"]

NAMESPACE_ENTERED = "TEST_UPGRADE_CONTAINER_NAMESPACE"


def dataset(**properties: str) -> Dict[str, Any]:
    return {"properties": properties}


#
# One boot environment, as an engine that has been upgraded in place
# carries it: the root filesystem mounted at "/", and the rest on legacy
# mountpoints that /etc/fstab drives. "tmp" and "vartmp" are the two a
# CIS-compliant engine has and an older one does not.
#
def inventory(tmp_datasets: bool) -> Dict[str, Any]:
    datasets = {
        "rpool/ROOT": dataset(),
        BOOT_ENVIRONMENT: dataset(**{
            "com.delphix:initial-version": VERSION,
            "com.delphix:current-version": VERSION,
            "com.delphix:minimum-version": VERSION,
        }),
        BOOT_ENVIRONMENT + "/root": dataset(mountpoint="/"),
        BOOT_ENVIRONMENT + "/home": dataset(mountpoint="legacy"),
        BOOT_ENVIRONMENT + "/data": dataset(mountpoint="legacy"),
        BOOT_ENVIRONMENT + "/log": dataset(mountpoint="legacy"),
    }

    if tmp_datasets:
        datasets[BOOT_ENVIRONMENT + "/tmp"] = dataset(mountpoint="legacy")
        datasets[BOOT_ENVIRONMENT + "/vartmp"] = dataset(mountpoint="legacy")

    return {"datasets": datasets}


class UpgradeContainerTestCase(unittest.TestCase):

    def setUp(self) -> None:
        #
        # The scratch space is taken from /tmp explicitly, since /var/tmp
        # is one of the directories bound over below.
        #
        self.scratch = tempfile.mkdtemp(prefix="test-upgrade-container.",
                                        dir="/tmp")
        self.addCleanup(shutil.rmtree, self.scratch, ignore_errors=True)

        for directory in SANDBOXED:
            self.sandbox(directory)

        self.inventory_path = os.path.join(self.scratch, "inventory.json")
        self.trace_path = os.path.join(self.scratch, "trace.txt")

    #
    # Bind a directory under the scratch space over the directory the
    # script writes to, so that nothing it writes lands on the host.
    #
    def sandbox(self, directory: str) -> None:
        source = os.path.join(self.scratch, directory.lstrip("/"))
        os.makedirs(source)
        subprocess.run(["mount", "--bind", source, directory], check=True)
        #
        # "--no-mtab" because umount(8) otherwise fails updating the
        # system's mount table, which it cannot write to from here, after
        # it has already unmounted the directory.
        #
        self.addCleanup(subprocess.run, ["umount", "--no-mtab", directory],
                        check=True)

    def run_upgrade_container(self, inv: Dict[str, Any],
                              *args: str) -> "subprocess.CompletedProcess[str]":
        with open(self.inventory_path, "w") as f:
            json.dump(inv, f)

        env = dict(os.environ,
                   PATH=STUBS_DIR + os.pathsep + os.environ["PATH"],
                   STUB_INVENTORY=self.inventory_path,
                   STUB_TRACE=self.trace_path)
        return subprocess.run([SCRIPT] + list(args),
                              env=env, capture_output=True, text=True)

    #
    # Creates a container, and returns its name together with the
    # datasets the pool is left holding.
    #
    def create(self, tmp_datasets: bool = True) -> Any:
        result = self.run_upgrade_container(inventory(tmp_datasets),
                                            "create", "in-place")
        self.assertEqual(result.returncode, 0, result.stderr)

        containers = os.listdir("/var/lib/machines")
        self.assertEqual(len(containers), 1, containers)

        return containers[0], self.datasets()

    def datasets(self) -> Dict[str, Any]:
        with open(self.inventory_path) as f:
            return json.load(f)["datasets"]

    # The datasets the container holds, by their last name component.
    def container_datasets(self, container: str) -> List[str]:
        prefix = "rpool/ROOT/{}/".format(container)
        return sorted(name[len(prefix):] for name in self.datasets()
                      if name.startswith(prefix))

    def umounts(self) -> List[str]:
        return [line for line in self.trace() if line.startswith("umount ")]

    def fstab(self, container: str) -> List[str]:
        with open("/var/lib/machines/{}/etc/fstab".format(container)) as f:
            return f.read().splitlines()

    # The line in the container's fstab that mounts the given directory.
    def fstab_entry(self, container: str, mountpoint: str) -> str:
        entries = [line for line in self.fstab(container)
                   if line.split()[1:2] == [mountpoint]]
        self.assertEqual(len(entries), 1,
                         "{} in {}".format(mountpoint, self.fstab(container)))
        return entries[0]

    def trace(self) -> List[str]:
        with open(self.trace_path) as f:
            return f.read().splitlines()

    def test_container_clones_the_tmp_datasets_of_its_boot_environment(
            self) -> None:
        #
        # The container is cloned from the boot environment, so it is the
        # boot environment's datasets that decide whether this container
        # gets /tmp and /var/tmp. Testing the container instead asks
        # about a dataset that was created empty moments earlier.
        #
        container, datasets = self.create()

        self.assertEqual(
            self.container_datasets(container),
            ["data", "home", "log", "root", "tmp", "vartmp"],
            "a boot environment made from this container loses /tmp and "
            "/var/tmp")

        for name in ["tmp", "vartmp"]:
            self.assertEqual(
                datasets["rpool/ROOT/{}/{}".format(container, name)]["origin"],
                "{}/{}@container-{}".format(BOOT_ENVIRONMENT, name,
                                            container))

    def test_the_tmp_datasets_are_looked_for_on_the_boot_environment(
            self) -> None:
        #
        # The look-up has to name the boot environment. Naming the
        # container asks about a dataset that has no name yet, and
        # zfs(8) rejects the empty component in "rpool/ROOT//tmp"
        # outright, so the answer is "no" whatever the engine holds.
        #
        self.create()

        self.assertEqual(
            [line for line in self.trace() if "//" in line], [],
            "zfs(8) rejects a name with an empty component whatever the "
            "pool holds")
        self.assertIn("zfs list {}/tmp".format(BOOT_ENVIRONMENT),
                      self.trace())

    def test_container_fstab_mounts_tmp_and_var_tmp(self) -> None:
        #
        # The fstab generated here is the one the container carries if it
        # becomes the boot environment, so a missing entry is what leaves
        # an upgraded engine with /tmp and /var/tmp as plain directories
        # on the root filesystem, without nosuid,nodev.
        #
        container, _ = self.create()

        for mountpoint, name in [("/tmp", "tmp"), ("/var/tmp", "vartmp")]:
            entry = self.fstab_entry(container, mountpoint)
            self.assertEqual(entry.split()[0],
                             "rpool/ROOT/{}/{}".format(container, name))
            options = entry.split()[3].split(",")
            self.assertIn("nosuid", options)
            self.assertIn("nodev", options)

    def test_container_has_no_tmp_datasets_without_them_on_the_source(
            self) -> None:
        #
        # The other side of the same decision: an engine whose boot
        # environment has no separate /tmp and /var/tmp has no snapshots
        # to clone, so neither the datasets nor the fstab entries may
        # appear.
        #
        container, _ = self.create(tmp_datasets=False)

        self.assertEqual(self.container_datasets(container),
                         ["data", "home", "log", "root"])

        mountpoints = [line.split()[1] for line in self.fstab(container)]
        self.assertNotIn("/tmp", mountpoints)
        self.assertNotIn("/var/tmp", mountpoints)

    def test_destroy_unmounts_the_containers_tmp_datasets(self) -> None:
        #
        # The container's datasets are mounted inside its root dataset,
        # so destroy() unmounts them before destroying it. A tmp or
        # vartmp dataset left mounted fails the recursive destroy that
        # follows.
        #
        container, _ = self.create()

        result = self.run_upgrade_container(
            {"datasets": self.datasets()}, "destroy", container)
        self.assertEqual(result.returncode, 0, result.stderr)

        self.assertEqual(
            self.umounts(),
            ["umount rpool/ROOT/{}/{}".format(container, name)
             for name in ["log", "data", "home", "tmp", "vartmp", "root"]],
            "destroy() left the tmp and vartmp datasets mounted")

        self.assertNotIn("rpool/ROOT/" + container, self.datasets())


#
# The script requires root and writes to directories outside the test's
# own scratch space, so the whole run happens in a user and mount
# namespace. Re-executing before unittest starts keeps every test in the
# same namespace, and the sentinel keeps the re-execution from repeating.
#
def enter_namespace() -> None:
    if os.environ.get(NAMESPACE_ENTERED):
        return

    if shutil.which("unshare") is None:
        sys.exit("must be run as root, and 'unshare' is not available")

    unshare = ["unshare", "--mount"]
    if os.geteuid() != 0:
        unshare.append("--map-root-user")

    os.environ[NAMESPACE_ENTERED] = "1"
    os.execvp("unshare",
              unshare + [sys.executable, os.path.realpath(__file__)] +
              sys.argv[1:])


if __name__ == "__main__":
    enter_namespace()
    unittest.main()
