The "configuration" folder contains all the common configuration hooks that need to be run before any other hooks are run.

The "upgrade-artifacts" folder contains the hooks to create upgrade artifacts.

The "vm-artifacts" folder contains the hooks to create VM artifacts.

The "tests" folder contains tests for the hooks. It holds no hooks of its own: run-live-build.sh copies only the "configuration" folder and the run type's own folder into a build, so nothing in "tests" runs as part of one.
