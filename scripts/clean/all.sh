#!/usr/bin/env bash
set -e
set -o pipefail

echo "Cleaning all databases and artifacts..."

echo "Are you sure you want to remove .stack-work directory? You will have to rebuild Bcc SL completely. Type 'yes' to continue..."
read -r DECISION
if [ "${DECISION}" == "yes" ]; then
    echo "Cleaning Bcc SL stack-work..."
    rm -rf .stack-work
    ./scripts/clean/db.sh
    ./scripts/clean/explorer-bridge.sh
    exit 0
else
    echo "Abort.";
    exit 1
fi
