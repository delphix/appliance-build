#!/usr/bin/env python3
#
# Tests for "rootfs-cleanup"'s container-snapshot filter.
#
# The filter at rootfs-cleanup:72-81 has two stated contracts: no
# "container-delphix" snapshot reaches the deletion-candidate list, because
# "rootfs-container delete" owns those, and every other snapshot name is
# checked against the guard at :87-88 before anything is deleted. The tests
# below hold it to both.
#
# They run the real script, with stand-ins for the three commands it shells
# out to ("zfs", "get-appliance-version" and "rootfs-container") on $PATH,
# over an inventory the test supplies. Nothing is needed beyond python3: no
# appliance, no pool, no root.
#
#   ./test-rootfs-cleanup.py
#
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from typing import Any, Dict, List

TESTS_DIR = os.path.dirname(os.path.realpath(__file__))
STUBS_DIR = os.path.join(TESTS_DIR, "rootfs-cleanup-stubs")
SCRIPT = os.path.join(TESTS_DIR, os.pardir, "rootfs-cleanup")

RUNNING = "rpool/ROOT/delphix.XiYgti1"
RUNNING_VERSION = "2026.5.0.1"
OLD = "rpool/ROOT/delphix.qs000AA"
OLD_VERSION = "2026.4.0.0"


def snapshot(name: str, version: str) -> Dict[str, str]:
    return {"name": "{}@{}".format(OLD, name), "version": version}


def inventory(snapshots: List[Dict[str, str]]) -> Dict[str, Any]:
    #
    # One boot environment being cleaned up, and the running one, which the
    # policy at rootfs-cleanup:106-116 always keeps. "rpool/ROOT" itself is
    # listed because the script expects it and removes it at :100.
    #
    return {
        "current": RUNNING_VERSION,
        "filesystems": [
            {"name": "rpool/ROOT", "version": "-"},
            {"name": RUNNING, "version": RUNNING_VERSION},
            {"name": OLD, "version": OLD_VERSION},
        ],
        "snapshots": snapshots,
    }


class RootfsCleanupTestCase(unittest.TestCase):

    def run_rootfs_cleanup(
            self, inv: Dict[str, Any]) -> "subprocess.CompletedProcess[str]":
        #
        # rootfs-cleanup:8 resolves "rootfs-container" next to itself, so the
        # script under test is copied in beside the stand-ins rather than run
        # from the source tree.
        #
        workdir = tempfile.mkdtemp(prefix="test-rootfs-cleanup.")
        self.addCleanup(shutil.rmtree, workdir)
        bindir = os.path.join(workdir, "bin")
        shutil.copytree(STUBS_DIR, bindir)
        shutil.copy(SCRIPT, bindir)

        self.inventory_path = os.path.join(workdir, "inventory.json")
        with open(self.inventory_path, "w") as f:
            json.dump(inv, f)
        self.trace_path = os.path.join(workdir, "trace.txt")

        env = dict(os.environ,
                   PATH=bindir + os.pathsep + os.environ["PATH"],
                   STUB_INVENTORY=self.inventory_path,
                   STUB_TRACE=self.trace_path)
        return subprocess.run([os.path.join(bindir, "rootfs-cleanup")],
                              env=env, capture_output=True, text=True)

    #
    # Every command the script issued, one per line, in order. The two
    # enumerations it starts from name no dataset, so a container snapshot
    # appearing here at all means the filter let it through.
    #
    def trace(self) -> List[str]:
        with open(self.trace_path) as f:
            return f.read().splitlines()

    def test_no_container_snapshot_reaches_the_candidate_list(self) -> None:
        #
        # Eleven container snapshots on one boot environment, which an
        # engine that has leaked upgrade containers accumulates. All eleven
        # belong to "rootfs-container delete" and none of them to this
        # script, so none may be looked at again after the filter.
        #
        snapshots = [snapshot("execute-upgrade.fx000AA", "2025.4.0.1")]
        snapshots += [snapshot("container-delphix.Ct000%02d" % n, OLD_VERSION)
                      for n in range(1, 12)]

        self.run_rootfs_cleanup(inventory(snapshots))

        escaped = [c for c in self.trace() if "container-delphix" in c]
        self.assertEqual(escaped, [],
                         "container snapshots reached the candidate list")

    def test_guard_rejects_unexpected_name_after_container_snapshot(
            self) -> None:
        #
        # The guard at :87-88 must see every name. Here the unexpected one
        # sits immediately after a container snapshot, the position the
        # filter is apt to skip.
        #
        result = self.run_rootfs_cleanup(inventory([
            snapshot("container-delphix.Aa00001", OLD_VERSION),
            snapshot("WHO-PUT-THIS-HERE", OLD_VERSION),
            snapshot("execute-upgrade.bb00002", "2025.4.0.1"),
        ]))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected snapshot name: 'WHO-PUT-THIS-HERE'",
                      result.stderr)
        self.assertEqual(self.destructive_commands(), [])

    def test_guard_rejects_unexpected_name_before_container_snapshot(
            self) -> None:
        #
        # The same name one slot earlier. This is the control for the test
        # above: it pins the guard's behaviour to the name, so a failure
        # there is the snapshot's position in the list and nothing else.
        #
        result = self.run_rootfs_cleanup(inventory([
            snapshot("WHO-PUT-THIS-HERE", OLD_VERSION),
            snapshot("container-delphix.Aa00001", OLD_VERSION),
            snapshot("execute-upgrade.bb00002", "2025.4.0.1"),
        ]))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpected snapshot name: 'WHO-PUT-THIS-HERE'",
                      result.stderr)
        self.assertEqual(self.destructive_commands(), [])

    def destructive_commands(self) -> List[str]:
        return [c for c in self.trace()
                if c.startswith("zfs destroy") or
                c.startswith("rootfs-container delete")]


if __name__ == "__main__":
    unittest.main(verbosity=2)
