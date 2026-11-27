#!/usr/bin/env bash
# Stage the pinned datagen wheels in a UC volume; the serverless task installs them from there.
set -euo pipefail
PROFILE=${1:?usage: stage_wheels.sh <profile> <catalog> [schema]}; CATALOG=${2:?catalog required}; SCHEMA=${3:-customs_permit_idp}
TMP=$(mktemp -d)
pip download -q --only-binary=:all: \
  --platform manylinux_2_28_x86_64 --platform manylinux2014_x86_64 --python-version 3.12 --implementation cp \
  -d "$TMP" reportlab==5.1.0 pillow==13.0.0 pypdfium2==5.15.2
databricks fs cp -r "$TMP" "dbfs:/Volumes/$CATALOG/$SCHEMA/libs/datagen" --overwrite -p "$PROFILE"
ls "$TMP"
