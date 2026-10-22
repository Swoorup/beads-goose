#!/bin/sh
# Builds the goose port and prints the path of its `bd` executable.
# Prints nothing (and exits 0) while there is no port to build yet; CI then
# skips the port lane. Replace the body once the goose build exists.
set -eu
