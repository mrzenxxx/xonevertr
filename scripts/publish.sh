#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Uses gh's credential store for this command only; never embeds credentials.
gh auth status
repository=https://github.com/mrzenxxx/xonevertr.git
if git remote get-url origin >/dev/null 2>&1; then
    remote_url=$(git remote get-url origin)
    case "$remote_url" in
        https://github.com/mrzenxxx/xonevertr.git|https://github.com/mrzenxxx/xonevertr|git@github.com:mrzenxxx/xonevertr.git) ;;
        *) printf 'Unexpected origin: %s\n' "$remote_url" >&2; exit 1 ;;
    esac
else
    git remote add origin "$repository"
fi
git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push -u origin main
