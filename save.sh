#!/usr/bin/env bash
# =============================================================================
# save.sh — Stage, commit, and push all project changes
# Usage: ./save.sh "your commit message"
#        If no message provided, auto-generates one with timestamp.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"

MSG="${1:-"chore: update $(date '+%Y-%m-%d %H:%M')"}"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"

echo "==> Staging all changes..."
git add -A

STATUS=$(git status --porcelain)
if [ -z "$STATUS" ]; then
    echo "==> Nothing to commit — working tree clean."
    exit 0
fi

echo "==> Changes to commit:"
git status --short

echo ""
echo "==> Committing: \"$MSG\""
git commit -m "$MSG"

echo ""
echo "==> Pushing to origin/${BRANCH}..."
git push origin "$BRANCH" || echo "WARNING: Push failed. Add a remote with: git remote add origin <url>"

echo ""
echo "==> Done!"
