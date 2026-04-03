#!/bin/bash
# Creates a symlink from the current directory to JourneyTester artifacts
# in the xctrunner sandbox. Run this from your project root after tests.
#
# Usage: ./link-artifacts.sh [bundle-id]
# Default bundle-id: com.journeytester.safari-uitests

BUNDLE_ID="${1:-com.journeytester.safari-uitests}"
CONTAINER="$HOME/Library/Containers/${BUNDLE_ID}.xctrunner/Data/.journeytester"

if [ -d "$CONTAINER" ]; then
    ln -sfn "$CONTAINER" .journeytester
    echo "Linked .journeytester -> $CONTAINER"
    echo "Journeys:"
    ls -1 "$CONTAINER/journeys/" 2>/dev/null
else
    echo "No artifacts found at: $CONTAINER"
    echo "Run tests first, then re-run this script."
    exit 1
fi
