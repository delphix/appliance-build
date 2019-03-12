# Delphix Appliance Build

![](https://github.com/delphix/appliance-build/workflows/.github/workflows/main.yml/badge.svg)

This repository contains the code used to build the Ubuntu-based Delphix
Appliance, leveraging open-source tools such as Debian's live-build,
Docker, Ansible, OpenZFS, and others. It is capable of producing virtual
machine images containing the Delphix Dynamic Data Platform, that are
capable of running in cloud and non-cloud hypervisors alike (e.g. Amazon
EC2, Microsoft Azure, VMware, OpenStack).

## Quickstart (for the impatient)

Run this command on "dlpxdc.co" to create the VM used to do the build:

    $ dc clone-latest --size COMPUTE_LARGE bootstrap-18-04 $USER-bootstrap

Log into that VM using the "ubuntu" user, and run these commands:

    $ git clone https://github.com/delphix/appliance-build.git
    $ cd appliance-build
    $ ansible-playbook bootstrap/playbook.yml
    $ sudo -E ./gradlew buildInternalMinimalKvm
    $ sudo qemu-system-x86_64 -nographic -m 1G \
    > -drive file=live-build/build/artifacts/internal-minimal-kvm.qcow2

To exit "qemu", use "Ctrl-A X".

## Build Requirements

The Delphix Appliance build system has the following assuptions about
the environment from which it will be executed:

 1. Ansible must be installed and available to be used on the host
    that'll run the build. An Ansible playbook is included in this
    repository, which captures nearly all of the runtime dependencies
    needed to execute the build. It is assumed that this playbook will
    be used to configure the host that's used to execute the build.

 2. The host that's used to execute the build must have access to
    Delphix's Artifactory service, as well as Delphix's AWS S3 buckets;
    generally this is accomplished by running the build within Delphix's
    VPN. This is required so that the build can download Delphix's Java
    distribution stored in Artifactory, along with the Delphix specific
    packages stored in S3.

## Getting Started

The following section will attempt to outline the steps required to
execute the build, resulting in the Delphix Appliance virtual machine
images.

### Step 1: Create Docker Host using DCenter on AWS

Delphix maintains the "bootstrap-18-04" group in DCenter on AWS that
fulfills the required build dependencies previously described. Thus, the
first step is to use this group to create the host that will be used to
execute the build. This can be done as usual, using "dc clone-latest".

Example commands running on "dlpxdc.co":

    $ export DLPX_DC_INSTANCE_PUB_KEY=~/.ssh/id_rsa.pub
    $ dc clone-latest --size COMPUTE_LARGE bootstrap-18-04 ps-build

Use the "ubuntu" user to log in to the VM after it's cloned; all of the
following steps assume their being run on the cloned VM.

### Step 2: Clone "appliance-build" Repository

Once the "bootstrap" DCenter on AWS VM is created, the "appliance-build"
repository needs to be populated on it. Generally this is done using
"git" primitives, e.g. "git clone", "git checkout", etc. For this
example, we'll do a new "git clone" of the upstream repository:

    $ git clone https://github.com/delphix/appliance-build.git
    $ cd appliance-build

### Step 3: Configure "bootstrap" VM

Next, we need to apply the "bootstrap" Ansible configuration, which will
verify all the necessary build dependencies are fulfilled, while also
correcting any deficencies that may exist. This is easily done like so:

    $ ansible-playbook bootstrap/playbook.yml

### Step 4: Run Live Build

Now, with the "bootstrap" VM properly configured, we can run the build:

    $ sudo -E ./gradlew ...

Each variant will have ansible roles applied according to playbooks in
per variant directories under live-build/variants. An appliance can be
built by invoking the gradle task for the variant and platform desired.
The task name has the form 'build\<Variant\>\<Platform\>'. For instance,
the task to build the 'internal-minimal' variant for KVM is
'buildInternalMinimalKvm':

    $ sudo -E ./gradlew buildInternalMinimalKvm

When this completes, the newly built VM artifacts will be contained in
the "live-build/build/artifacts/" directory:

    $ ls -lh live-build/build/artifacts/
    total 1.9G
    -rw-r--r-- 1 root root 275M Jan 11 22:31 internal-minimal-kvm.debs.tar.gz
    -rw-r--r-- 1 root root   45 Jan 11 22:31 internal-minimal-kvm.migration.tar.gz
    -rw-r--r-- 1 root root 636M Jan 11 22:33 internal-minimal-kvm.qcow2

The appliance produced will contain a kernel optimized for the
specified platform (which can be one of 'aws', 'azure', 'esx', 'gcp',
or 'kvm'). The appliance will also contain kernel modules built for
that optimized kernel, and perhaps some other modules relevant to that
platform only.

### Step 5: Use QEMU for Boot Verfication

Once the live-build artifacts have been generated, we can then leverage
the "qemu" tool to test the "qcow2" artifact:

    $ sudo qemu-system-x86_64 -nographic -m 1G \
    > -drive file=live-build/build/artifacts/internal-minimal-kvm.qcow2

This will attempt to boot the "qcow2" VM image, minimally verifying that
any changes to the build don't cause a boot failure. Further, after the
image boots (assuming it boots successfully), one can log in via the
console (username and password are both 'delphix') and perform any
post-boot verification that's required (e.g. verify certain packages are
installed, etc).

To exit "qemu", one can use "Ctrl-A X".

## Building an Upgrade Image

An upgrade image for a particular variant can be built by running the
'buildUpgradeImage\<Variant\>' tasks. For instance, the task to build
an upgrade image for the internal-minimal variant is
'buildUpgradeImageInternalMinimal':

    $ DELPHIX_PLATFORMS='kvm aws' sudo -E ./gradlew buildUpgradeImageInternalMinimal

An upgrade image can contain the necessary packages to upgrade
appliances running on multiple different platforms. Which platforms are
supported by a particular upgrade image is determined by the list of
platforms specified in the `DELPHIX_PLATFORMS` environment variable. When the
build completes, the upgrade image can be found in the "build/artifacts"
directory:

    $ ls -lh build/artifacts/
    total 837M
    -rw-r--r-- 1 root root 837M Jan 11 22:35 internal-minimal.upgrade.tar

## Using Gradle

As noted in the previous sections, the build logic is implemented using
Gradle. The most commonly used tasks are likely to be

 - `build<Variant><Platform>` - Builds the given variant of the appliance for the given platform
 - `buildUpgradeImage<Variant>` - Builds an upgrade image for the given variant
 - `check` - Runs all style checks
 - `format` - Runs all code formatting tasks
 - `clean` - Removes all existing build artifacts

The complete list of tasks can be listed using the 'tasks' task:

    $ ./gradlew tasks

## Creating new build variants

This repository contains different build variants which are used to
generate customized images, leveraging different Ansible roles to customize
those variants. The following instructions can be used to create a new
build variant and roles.

### Step 1. Create the build variant

The different variants are located in the "live-build/variants" directory:

    $ ls -l live-build/variants
    total 0
    drwxr-xr-x  5 root  root  160 Jun  4 22:56 external-standard
    drwxr-xr-x  5 root  root  160 Jun  4 22:56 internal-dev
    drwxr-xr-x  5 root  root  160 Jun  4 22:56 internal-minimal
    drwxr-xr-x  5 root  root  160 Jun  4 22:56 internal-qa

To create a new variant, run the "create-variant.sh" script. Note that
variant names use the "internal" and "external" prefixes:

    $ ./scripts/create-variant.sh internal-dcenter

### Step 2. Create and populate the ansible role directory

The new variant that was just created may require some customizations applied
to it, that are specific to this new variant. In order to apply these
customization, a new Ansible role can be created and used. All existing Ansible
roles that are used to customize existing build variants are located in the
"live-build/misc/ansible-roles" directory, and follow the standard Ansible role
directory structure (i.e. tasks, handlers, files, etc.)

To create a new Ansible role, a new Ansible role directory will need to be
created. In this example, the name of our Ansible role will be
"appliance-build.dcenter" to match the name of our variant:

    $ mkdir -p live-build/misc/ansible-roles/appliance-build.dcenter/tasks

There are many roles that exist in "live-build/misc/ansible-roles" which can
serve as good examples.

### Step 3. Update the variant configuration

With the role[s] created, you can populate the "playbook.yml" file in the
new variant's "ansible" directory:

    $ ls -l live-build/variants/internal-dcenter/ansible
    total 8
    -rw-r--r--  1 root  root  891 Jun 29 14:43 playbook.yml
    lrwxr-xr-x  1 root  root   27 Jun 19 19:17 roles -> ../../../misc/ansible-roles

For this example, we add our new role to the playboodk as shown below:

    ---
    - hosts: all
      connection: chroot
      gather_facts: no
      vars:
        ansible_python_interpreter: /usr/bin/python3
      roles:
        - appliance-build.minimal-common
        - appliance-build.minimal-internal
        - appliance-build.dcenter

### Step 4. Build the variant

See the instructions [above](#step-4-run-live-build) to setup your build
environment and kick off the build:

    $ sudo -E ./gradlew buildInternalDcenterEsx

## Contributing

All contributors are required to sign the Delphix Contributor Agreement prior
to contributing code to an open source repository. This process is handled
automatically by [cla-assistant](https://cla-assistant.io/). Simply open a pull
request and a bot will automatically check to see if you have signed the latest
agreement. If not, you will be prompted to do so as part of the pull request
process.

This project operates under the [Delphix Code of
Conduct](https://delphix.github.io/code-of-conduct.html). By participating in
this project you agree to abide by its terms.

## Statement of Support

This software is provided as-is, without warranty of any kind or commercial
support through Delphix. See the associated license for additional details.
Questions, issues, feature requests, and contributions should be directed to
the community as outlined in the [Delphix Community
Guidelines](https://delphix.github.io/community-guidelines.html).

## License

This is code is licensed under the Apache License 2.0. Full license is
available [here](./LICENSE).
