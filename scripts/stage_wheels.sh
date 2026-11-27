#!/usr/bin/env bash
# Stage the pinned datagen wheels (x86_64 + aarch64) and a requirements file in a UC volume;
# the serverless task installs them from there, picking the wheel for its platform.
set -euo pipefail
PROFILE=${1:?usage: stage_wheels.sh <profile> <catalog> [schema]}; CATALOG=${2:?catalog required}; SCHEMA=${3:-customs_permit_idp}
VOL="/Volumes/$CATALOG/$SCHEMA/libs/datagen"
TMP=$(mktemp -d)
for ARCH in x86_64 aarch64; do
  pip download -q --only-binary=:all: \
    --platform "manylinux_2_28_$ARCH" --platform "manylinux2014_$ARCH" --python-version 3.12 --implementation cp \
    -d "$TMP" reportlab==5.1.0 pillow==13.0.0 pypdfium2==5.15.2
done
printf -- '--no-index\n--find-links %s\nreportlab==5.1.0\npillow==13.0.0\npypdfium2==5.15.2\n' "$VOL" > "$TMP/requirements.txt"
databricks fs cp -r "$TMP" "dbfs:$VOL" --overwrite -p "$PROFILE"
ls "$TMP"
