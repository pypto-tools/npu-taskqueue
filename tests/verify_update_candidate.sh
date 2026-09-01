#!/usr/bin/env bash
# Unprivileged checks run before a repository-controlled target is installed.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

bash -n task-daemon.sh task-submit.sh setup.sh deploy.sh npu_lock.sh \
    scripts/repo-auto-update-deploy.sh scripts/repo-auto-update-adapter.sh \
    modules/repo_auto_update/updater.sh
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH="$REPO_DIR" \
    python3 -m unittest discover -s tests -p 'test_update_manifest.py'
bash tests/test_scheduler_core.sh
bash tests/test_pool_aware_reservation.sh
bash tests/test_device_group_affinity.sh
bash tests/test_eight_card_limit.sh
bash tests/test_auto_update_retry.sh
bash tests/test_deploy_upgrade_guard.sh
bash tests/test_repo_auto_update_adapter.sh
bash tests/test_repo_auto_update_layout.sh

echo 'repository-controlled update candidate tests passed'
