#!/usr/bin/env bash
# run-vm.sh -- VM script. Runs INSIDE the test VM as user 'tester'.
#
# Simulates a real user following the README on a clean Ubuntu 24.04 machine:
#   1. Install git
#   2. Clone the repo from GitHub
#   3. Run bootstrap.sh
#
# This script is injected into the VM by create-vm.sh and runs entirely
# inside the VM -- it has no dependency on the host machine or local files.
#
# Usage (from inside the VM):
#   bash run-vm.sh
#
# Override the repo URL if testing a fork:
#   REPO_URL=https://github.com/your-fork/... bash run-vm.sh

set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/vitorco7/desafio-devops-prefeitura-rj.git}"
REPO_DIR="$HOME/desafio-devops-prefeitura-rj"

echo "============================================================"
echo "  Fresh install reproducibility test"
echo "  Repo: $REPO_URL"
echo "  User: $(whoami)"
echo "  OS  : $(. /etc/os-release && echo "$PRETTY_NAME")"
echo "============================================================"
echo ""

# -- Step 1: Install git -------------------------------------------------------
# git may already be installed by create-vm.sh, but we ensure it here so this
# script is self-contained and works even if create-vm.sh was interrupted.
echo "[1/3] Ensuring git is installed..."
if ! command -v git &>/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y --no-install-recommends git
fi
echo "      $(git --version)"

# -- Step 2: Clone repo from GitHub --------------------------------------------
echo "[2/3] Cloning repo from GitHub..."
if [ -d "$REPO_DIR/.git" ]; then
  echo "      Repo already cloned, pulling latest..."
  git -C "$REPO_DIR" pull
else
  git clone "$REPO_URL" "$REPO_DIR"
fi
echo "      Cloned to $REPO_DIR"

# -- Step 3: Run bootstrap.sh --------------------------------------------------
# NOTE: bootstrap.sh does 'exec sg incus <script>' when it adds the user to
# the incus group. That exec replaces the current shell -- this is expected
# and bootstrap.sh re-runs itself from the top, skipping completed steps.
echo "[3/3] Running bootstrap.sh..."
echo "      (Expected time: 15-25 min on first run)"
echo "------------------------------------------------------------"

cd "$REPO_DIR"
bash scripts/bootstrap.sh
