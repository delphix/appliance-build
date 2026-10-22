#!/usr/bin/env python3
#
# Tests for what "upgrade-container" leaves behind when a container cannot
# be stopped.
#
# destroy() is reached with the container still running whenever stop()
# fails, and the recursive destroy it then attempts cannot succeed: the
# container's "root" dataset is mounted under /var/lib/machines. What the
# tests below hold the script to is that the failed destroy leaves the
# orphan findable - is_upgrade_container() still recognises it, so
# list-all reports it and cleanup reclaims it once the container can be
# terminated.
#
# They run the real script inside a user and mount namespace, with
# stand-ins for the commands it shells out to on $PATH and tmpfs over the
# three directories it reads and writes. Nothing is needed beyond python3
# and unshare(1): no appliance, no pool, no root.
#
#   ./test-upgrade-container-teardown.py
#
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from typing import Any, Dict, List

TESTS_DIR = os.path.dirname(os.path.realpath(__file__))
STUBS_DIR = os.path.join(TESTS_DIR, "upgrade-container-stubs")
SANDBOX = os.path.join(TESTS_DIR, "upgrade-container-sandbox.sh")
SCRIPTS_DIR = os.path.join(TESTS_DIR, os.pardir)

CONTAINER = "delphix.Ct00001"
BOOT_ENVIRONMENT = "rpool/ROOT/delphix.oiknl78"
CHILDREN = ["root", "data", "home", "log"]


def state(running: bool, terminate_succeeds: bool = True) -> Dict[str, Any]:
    #
    # An engine carrying one upgrade container: the running boot
    # environment, the container cloned from it, and the recursive
    # snapshot create() took of the boot environment to clone it.
    #
    container = "rpool/ROOT/" + CONTAINER
    datasets = [BOOT_ENVIRONMENT, container]
    datasets += [d + "/" + c for d in (BOOT_ENVIRONMENT, container)
                 for c in CHILDREN]
    return {
        "rootfs_dataset": BOOT_ENVIRONMENT,
        "datasets": datasets,
        "snapshots": ["{}@container-{}".format(d, CONTAINER)
                      for d in [BOOT_ENVIRONMENT] +
                      [BOOT_ENVIRONMENT + "/" + c for c in CHILDREN]],
        "running": [CONTAINER] if running else [],
        "terminate_succeeds": terminate_succeeds,
    }


class Sandbox:
    """One namespace, one container, and the steps run against it."""

    def __init__(self, workdir: str, initial: Dict[str, Any]) -> None:
        self.workdir = workdir
        self.initial = initial

    def path(self, *parts: str) -> str:
        return os.path.join(self.workdir, *parts)

    def run(self, steps: List[str]) -> None:
        bindir = self.path("bin")
        shutil.copytree(STUBS_DIR, bindir)
        for script in ("upgrade-container", "common.sh"):
            shutil.copy(os.path.join(SCRIPTS_DIR, script), bindir)

        #
        # What the three directories hold when the steps start: a
        # container that was created and started the ordinary way.
        #
        nspawn = self.path("fixture", "etc-systemd", "nspawn")
        os.makedirs(nspawn)
        with open(os.path.join(nspawn, CONTAINER + ".nspawn"), "w") as f:
            f.write("[Exec]\nBoot=on\n")
        override = self.path("fixture", "etc-systemd", "system",
                             "systemd-nspawn@" + CONTAINER + ".service.d")
        os.makedirs(override)
        with open(os.path.join(override, "override.conf"), "w") as f:
            f.write("[Service]\nTimeoutStopSec=infinity\n")
        os.makedirs(self.path("fixture", "var-lib-machines", CONTAINER))

        with open(self.path("state.json"), "w") as f:
            json.dump(self.initial, f)
        with open(self.path("steps.txt"), "w") as f:
            f.write("".join(step + "\n" for step in steps))
        open(self.path("trace.txt"), "w").close()

        self.steps = steps
        result = subprocess.run(
            ["unshare", "--map-root-user", "--mount", "--",
             SANDBOX, self.workdir],
            capture_output=True, text=True)
        if result.returncode != 0:
            raise AssertionError("sandbox failed: " + result.stderr)

    def rc(self, step: int) -> int:
        with open(self.path("step-%d.rc" % step)) as f:
            return int(f.read())

    def stderr(self, step: int) -> str:
        with open(self.path("step-%d.err" % step)) as f:
            return f.read()

    def stdout(self, step: int) -> str:
        with open(self.path("step-%d.out" % step)) as f:
            return f.read()

    # The container's own datasets; the boot environment's are not its to take.
    def container_datasets(self) -> List[str]:
        with open(self.path("state.json")) as f:
            datasets = json.load(f)["datasets"]
        return [d for d in datasets
                if d == "rpool/ROOT/" + CONTAINER or
                d.startswith("rpool/ROOT/" + CONTAINER + "/")]

    def snapshots(self) -> List[str]:
        with open(self.path("state.json")) as f:
            return json.load(f)["snapshots"]

    # The contents of the three directories once every step has run.
    def after(self, directory: str) -> List[str]:
        with open(self.path("after.txt")) as f:
            sections = f.read().split("## ")
        for section in sections:
            if section.startswith(directory + "\n"):
                return section.splitlines()[1:]
        raise AssertionError("no listing for " + directory)


class UpgradeContainerTeardownTestCase(unittest.TestCase):

    def sandbox(self, initial: Dict[str, Any], steps: List[str]) -> Sandbox:
        workdir = tempfile.mkdtemp(prefix="test-upgrade-container.")
        self.addCleanup(shutil.rmtree, workdir)
        box = Sandbox(workdir, initial)
        box.run(steps)
        return box

    def test_failed_destroy_leaves_the_orphan_findable(self) -> None:
        #
        # The teardown an engine performs when stop() has failed: the
        # container is still running, so the recursive destroy fails, and
        # what it has already removed by then decides whether anyone can
        # find the container afterwards. is_upgrade_container() needs the
        # .nspawn file, and list-all is the only command that enumerates
        # containers at all.
        #
        box = self.sandbox(state(running=True), [
            "upgrade-container destroy " + CONTAINER,
            "upgrade-container list-all",
        ])

        self.assertEqual(box.rc(1), 1, box.stderr(1))
        self.assertIn("failed to destroy container dataset", box.stderr(1))

        self.assertIn(CONTAINER + ".nspawn", box.after("/etc/systemd/nspawn"))
        self.assertEqual(box.stdout(2).split(), [CONTAINER])

    def test_cleanup_reclaims_the_container_once_it_can_be_terminated(
            self) -> None:
        #
        # A transient stop failure tears the container down
        # destructively; the transient then clears, and
        # "cleanup <container>" is the supported command for finishing the
        # job. It gates on is_upgrade_container(), so it can only work if
        # the failed destroy above left the markers alone.
        #
        box = self.sandbox(state(running=True), [
            "upgrade-container destroy " + CONTAINER,
            "machinectl terminate " + CONTAINER,
            "upgrade-container cleanup " + CONTAINER,
        ])

        self.assertEqual(box.rc(2), 0, box.stderr(2))
        self.assertEqual(box.rc(3), 0, box.stderr(3))

        self.assertEqual(box.container_datasets(), [])
        self.assertEqual(box.snapshots(), [])
        self.assertEqual(box.after("/etc/systemd/nspawn"), [])
        self.assertEqual(box.after("/etc/systemd/system"), [])
        self.assertEqual(box.after("/var/lib/machines"), [])

    def test_destroy_removes_everything_when_the_container_is_stopped(
            self) -> None:
        #
        # The ordinary teardown, which is what the two tests above must
        # not cost. Every marker, dataset and snapshot the container owns
        # goes, and the script reports success.
        #
        box = self.sandbox(state(running=False), [
            "upgrade-container destroy " + CONTAINER,
            "upgrade-container list-all",
        ])

        self.assertEqual(box.rc(1), 0, box.stderr(1))
        self.assertEqual(box.container_datasets(), [])
        self.assertEqual(box.snapshots(), [])
        self.assertEqual(box.after("/etc/systemd/nspawn"), [])
        self.assertEqual(box.after("/etc/systemd/system"), [])
        self.assertEqual(box.after("/var/lib/machines"), [])
        self.assertEqual(box.stdout(2), "")

    def test_cleanup_destroys_nothing_while_the_container_will_not_stop(
            self) -> None:
        #
        # cleanup() stops before it destroys, so a stop failure that has
        # not cleared must cost nothing at all - the orphan stays whole,
        # and findable, for the next attempt.
        #
        box = self.sandbox(state(running=True, terminate_succeeds=False), [
            "upgrade-container cleanup " + CONTAINER,
            "upgrade-container list-all",
        ])

        self.assertEqual(box.rc(1), 1)
        self.assertIn("failed to termiante container", box.stderr(1))

        self.assertEqual(len(box.container_datasets()), 1 + len(CHILDREN))
        self.assertEqual(len(box.snapshots()), 1 + len(CHILDREN))
        self.assertIn(CONTAINER + ".nspawn", box.after("/etc/systemd/nspawn"))
        self.assertEqual(box.stdout(2).split(), [CONTAINER])


if __name__ == "__main__":
    unittest.main(verbosity=2)
