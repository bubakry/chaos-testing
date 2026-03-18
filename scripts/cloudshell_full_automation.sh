#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TF_VERSION="${TF_VERSION:-1.14.5}"
SKIP_IMAGE_BUILD="${SKIP_IMAGE_BUILD:-true}"
SOURCE_IMAGE_REPO_NAME="${SOURCE_IMAGE_REPO_NAME:-chaos-game-day-demo-chaos-api}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require aws
require curl
require unzip

if ! command -v terraform >/dev/null 2>&1; then
  echo "Terraform not found. Installing terraform ${TF_VERSION} to ~/bin ..."
  TMP_DIR="$(mktemp -d)"
  ZIP_PATH="${TMP_DIR}/terraform.zip"

  curl -fsSL -o "$ZIP_PATH" "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip"
  unzip -q "$ZIP_PATH" -d "$TMP_DIR"

  mkdir -p "$HOME/bin"
  mv "$TMP_DIR/terraform" "$HOME/bin/terraform"
  chmod +x "$HOME/bin/terraform"
  export PATH="$HOME/bin:$PATH"

  rm -rf "$TMP_DIR"
fi

if ! command -v terraform >/dev/null 2>&1; then
  echo "Terraform install failed." >&2
  exit 1
fi

echo "Running CloudShell automation mode"
echo "- Terraform: $(terraform version | head -n 1)"
echo "- SKIP_IMAGE_BUILD=${SKIP_IMAGE_BUILD}"
echo "- SOURCE_IMAGE_REPO_NAME=${SOURCE_IMAGE_REPO_NAME}"

echo
SKIP_IMAGE_BUILD="$SKIP_IMAGE_BUILD" \
SOURCE_IMAGE_REPO_NAME="$SOURCE_IMAGE_REPO_NAME" \
"${SCRIPT_DIR}/aws_full_automation.sh"
