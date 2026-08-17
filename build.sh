#!/usr/bin/env bash
set -euo pipefail

PACKAGE_DIR="terraform/build/package"
PYTHON_VERSION="3.13"
PLATFORM="manylinux2014_aarch64"
PIP="${PIP:-.venv/bin/pip}"

rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"

"$PIP" install \
  --platform "$PLATFORM" \
  --only-binary=:all: \
  --python-version "$PYTHON_VERSION" \
  --implementation cp \
  --target "$PACKAGE_DIR" \
  --quiet \
  -r lambda/requirements.txt

cp lambda/process_data.py "$PACKAGE_DIR/"

find "$PACKAGE_DIR" -type d -name "__pycache__" -prune -exec rm -rf {} +
find "$PACKAGE_DIR" -type d -name "tests" -prune -exec rm -rf {} +
find "$PACKAGE_DIR" -type f -name "*.pyc" -delete

echo "package contents:"
ls "$PACKAGE_DIR"
echo "unzipped size: $(du -sh "$PACKAGE_DIR" | cut -f1)"
