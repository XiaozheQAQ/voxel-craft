#!/usr/bin/env bash
# Voxel Craft -- minimal static deployment artifact builder.
#
# No npm/framework dependency: this is a plain file-copy script. Both
# community.html and index.html are already self-contained, no-build-step
# single files, so "build" here means exactly one thing: produce two
# ISOLATED output directories, each containing ONLY the one page that
# origin is allowed to serve -- never both. This is the release-blocking
# security requirement from PUBLIC_BETA_DEPLOYMENT.md: the authenticated
# Community Portal and the Mod-executing Runtime must never be
# deployable from the same origin, and that starts with never being in
# the same deployment ARTIFACT in the first place.
set -euo pipefail
cd "$(dirname "$0")"

rm -rf dist-community dist-play
mkdir -p dist-community dist-play

cp community.html dist-community/index.html
cp _headers dist-community/_headers

cp index.html dist-play/index.html
cp _headers dist-play/_headers

echo "Built dist-community/ (from community.html) and dist-play/ (from index.html)."
