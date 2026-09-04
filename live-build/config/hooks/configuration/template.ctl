Section: metapackages
Priority: optional
Maintainer: Delphix Engineering <eng@delphix.com>
Standards-Version: 3.9.2

#
# "hotfix_metadata" is read by the upgrade-verify "HotfixCheck", so it cannot
# live in the "Extra-Files" documentation directory. dh_compress gzips any file
# in /usr/share/doc larger than 4k, and that check only ever looks for the
# uncompressed name, so the file silently disappeared out from under it once the
# hotfix list grew past 4096 bytes (DLPX-98834).
#
# Debian Policy 12.3 covers this case directly: packages must not require files
# in /usr/share/doc in order to function, and files read by programs belong
# elsewhere (such as under /usr/share/<package>) with a symlink from the doc
# directory. That's what the "Files" and "Links" fields below do; nothing needs
# to change in the consumer, since the historical path still resolves.
#
# "packages.list" deliberately stays in "Extra-Files": it is always well over
# 4k, and its consumers already read "packages.list.gz".
#
Package: delphix-entire-@@PLATFORM@@
Provides: delphix-entire
Version: @@VERSION@@
Extra-Files: packages.list, variant
Files: hotfix_metadata /usr/share/delphix-entire-@@PLATFORM@@/
Links: /usr/share/delphix-entire-@@PLATFORM@@/hotfix_metadata /usr/share/doc/delphix-entire-@@PLATFORM@@/hotfix_metadata
Description: Entirety of Delphix Appliance
 This package depends on all of the packages that constitute the entirety of
 the Delphix Appliance. This set of packages provide the necessary tools to run
 a root filesystem on OpenZFS, provide various utilities to facilitate
 efficient debugging of common problems, as well as provide any first-party
 Delphix application packages and their dependencies.
