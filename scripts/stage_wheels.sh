#!/usr/bin/env bash
# Stage pinned datagen wheels (from your PyPI mirror) in a UC volume for serverless.
set -euo pipefail
PROFILE=${1:?usage: stage_wheels.sh <profile> <catalog> [schema]}; CATALOG=${2:?catalog required}; SCHEMA=${3:-customs_permit_idp}
: "${PIP_INDEX_URL:?set PIP_INDEX_URL to your PyPI mirror}"
TMP=$(mktemp -d)
pip download -q --index-url "$PIP_INDEX_URL" --only-binary=:all: \
  --platform manylinux_2_28_x86_64 --platform manylinux2014_x86_64 --python-version 3.12 --implementation cp \
  -d "$TMP" reportlab==5.1.0 pillow==13.0.0 pypdfium2==5.15.2
databricks fs cp -r "$TMP" "dbfs:/Volumes/$CATALOG/$SCHEMA/libs/datagen" --overwrite -p "$PROFILE"
ls "$TMP"
