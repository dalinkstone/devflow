#!/bin/sh
set -eu
installer="$(mktemp)"
trap 'rm -f "$installer"' 0 1 2 15
curl -fsSL https://raw.githubusercontent.com/dalinkstone/devflow/main/install.sh -o "$installer"
bash "$installer"
