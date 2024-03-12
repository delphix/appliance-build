# Frequently Asked Questions

## What is an "upgrade container"?

An "upgrade container" is a collection of ZFS datasets that can be used
in conjunction with systemd-nspawn to verify an upgrade in a container,
prior to executing the upgrade and modifying the actual root filesystem
of the appliance.

To create and start an upgrade container, the "upgrade-container" script
can be used:

    $ /var/dlpx-update/latest/upgrade-container create in-place
    delphix.uE0noy5
    $ /var/dlpx-update/latest/upgrade-container start delphix.uE0noy5

This will clone the currently running root filesystem, mount it in
"/var/lib/machines", and then start a new instance of the systemd-nspawn
service to run the container.

Here's an example of the datasets that're created:

    $ zfs list -r -d 1 rpool/ROOT/delphix.uE0noy5
    NAME                              USED  AVAIL     REFER  MOUNTPOINT
    rpool/ROOT/delphix.uE0noy5       3.42M  39.3G       64K  none
    rpool/ROOT/delphix.uE0noy5/data  3.16M  39.3G     45.7M  legacy
    rpool/ROOT/delphix.uE0noy5/home     1K  39.3G     11.0G  legacy
    rpool/ROOT/delphix.uE0noy5/root   196K  39.3G     6.35G  /var/lib/machines/delphix.uE0noy5

Here's an example of the status of the systemd-nspawn service:

    $ systemctl status systemd-nspawn@delphix.uE0noy5 | head -n 11
    ● systemd-nspawn@delphix.uE0noy5.service - Container delphix.uE0noy5
       Loaded: loaded (/lib/systemd/system/systemd-nspawn@.service; disabled; vendor preset: enabled)
      Drop-In: /etc/systemd/system/systemd-nspawn@delphix.uE0noy5.service.d
               └─override.conf
       Active: active (running) since Tue 2019-01-29 19:41:04 UTC; 15min ago
         Docs: man:systemd-nspawn(1)
     Main PID: 2837 (systemd-nspawn)
       Status: "Container running: Startup finished in 49.256s."
        Tasks: 1 (limit: 16384)
       CGroup: /machine.slice/systemd-nspawn@delphix.uE0noy5.service
               └─2837 /usr/bin/systemd-nspawn --quiet --boot --capability=all --machine=delphix.uE0noy5

## What is an "in-place" upgrade container?

When creating an upgrade container, one can create either an "in-place"
upgrade container, or a "not-in-place" upgrade container. An in-place
container will have its "root" dataset be a clone of the root dataset of
the currently booted root filesystem; i.e. it's created with "zfs clone"
as opposed to "zfs create".

For example, the ZFS datasets for an in-place upgrade container will
resemble the following:

    $ /var/dlpx-update/latest/upgrade-container create in-place
    delphix.4qL2URY

    $ zfs list -r -d 1 -o name,mountpoint,origin rpool/ROOT/delphix.4qL2URY
    NAME                             MOUNTPOINT                         ORIGIN
    rpool/ROOT/delphix.4qL2URY       none                               -
    rpool/ROOT/delphix.4qL2URY/data  legacy                             rpool/ROOT/delphix.JNHeZad/data@delphix.4qL2URY
    rpool/ROOT/delphix.4qL2URY/home  legacy                             rpool/ROOT/delphix.JNHeZad/home@delphix.4qL2URY
    rpool/ROOT/delphix.4qL2URY/root  /var/lib/machines/delphix.4qL2URY  rpool/ROOT/delphix.JNHeZad/root@delphix.4qL2URY

## What is a "not-in-place" upgrade container?

When creating an upgrade container, one can create either an "in-place"
upgrade container, or a "not-in-place" upgrade container. A not-in-place
container will have its "root" dataset be seperate from any other root
dataset on the appliance; i.e. it's created with "zfs create" as opposed
to "zfs clone".

For example, the ZFS datasets for an in-place upgrade container will
resemble the following:

    $ /var/dlpx-update/latest/upgrade-container create not-in-place
    ...
    delphix.Oy4JfnU

    $ sudo zfs list -r -d 1 -o name,mountpoint,origin rpool/ROOT/delphix.Oy4JfnU
    NAME                             MOUNTPOINT                         ORIGIN
    rpool/ROOT/delphix.Oy4JfnU       none                               -
    rpool/ROOT/delphix.Oy4JfnU/data  legacy                             rpool/ROOT/delphix.JNHeZad/data@delphix.Oy4JfnU
    rpool/ROOT/delphix.Oy4JfnU/home  legacy                             rpool/ROOT/delphix.JNHeZad/home@delphix.Oy4JfnU
    rpool/ROOT/delphix.Oy4JfnU/root  /var/lib/machines/delphix.Oy4JfnU  -

## What is a "rootfs container"?

A "rootfs container" is a collection of ZFS datasets that can be used as
the "root filesytsem" of the appliance. This includes a dataset for "/"
of the appliance, but also seperate datasets for "/home" and
"/var/delphix".

Here's an example of the datasets for a rootfs container:

    $ sudo zfs list -r -d 1 -o name,mountpoint,origin rpool/ROOT/delphix.Oy4JfnU
    NAME                             MOUNTPOINT  ORIGIN
    rpool/ROOT/delphix.Oy4JfnU       none        -
    rpool/ROOT/delphix.Oy4JfnU/data  legacy      rpool/ROOT/delphix.JNHeZad/data@delphix.Oy4JfnU
    rpool/ROOT/delphix.Oy4JfnU/home  legacy      rpool/ROOT/delphix.JNHeZad/home@delphix.Oy4JfnU
    rpool/ROOT/delphix.Oy4JfnU/root  /           -

## What is the difference between upgrade and rootfs containers?

The two main distictions between an upgrade container and a rootfs
container are the following:

 1. The mountpoint of the container's "root" dataset is different; for
    upgrade container's it'll be "/var/lib/machines/...", whereas it'll
    be "/" for a rootfs container.

 2. Due to the first difference, a rootfs contianer can be used as the
    root filesystem of the appliance when the appliance boots. An
    upgrade container cannot be used to boot the appliance; it can only
    be used to start a system-nspawn machine container.
