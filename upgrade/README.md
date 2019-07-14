# Delphix Appliance Upgrade

This directory contains the code used to upgrade an Ubuntu-based Delphix
Appliance, leveraging common Ubuntu packaging tools such as `dpkg(1)`,
`apt-get(8)`, `debootstrap(8)`, and others. It is capable of consuming
an "upgrade image", and using this image to upgrade an existing Delphix
Appliance; the upgrade image's are produced by the appliance build.

## Purpose

The main goal(s) of upgrade are the following:

1. Enable the upgrade of all packages on a given appliance, using only
   the upgrade image (these scripts are contained in the upgrade image);
   once the upgrade image is present on the appliance, no other network
   connectivity is required.

2. Prevent upgrade failures from occuring, since a failure can result in
   the appliance being left in a degraded, and sometimes unrecoverable,
   state. We accomplish this by verifying upgrade, prior to actually
   executing the upgrade.

3. Enable all packages to be upgraded without requiring a downtime; e.g.
   without requiring a reboot. While we've accomplished this, in that
   all packages can be upgraded without a reboot, certain software
   requires a reboot in order to run the new software delivered by the
   upgraded package(s). For example, even though we can install a new
   kernel package without a reboot, we need to reboot in order to start
   using the software delivered by that new kernel package.

## Quickstart

Run this command on "dlpxdc.co" to create the VM used to do the upgrade:

    $ dc clone-latest --size DATABASE_LARGE dlpx-trunk $USER-trunk

Log into that VM using the "delphix" user, and run these commands:

    $ download-latest-image internal-dev
    $ sudo unpack-image internal-dev.upgrade.tar.gz
    $ sudo /var/dlpx-update/latest/upgrade -v deferred

## FAQ

See the [FAQ](FAQ.md) for answers to commonly asked questions.

## Statement of Support

This software is provided as-is, without warranty of any kind or
commercial support through Delphix. See the associated license for
additional details. Questions, issues, feature requests, and
contributions should be directed to the community as outlined in the
[Delphix Community Guidelines](http://delphix.github.io/community-guidelines.html).
