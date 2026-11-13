#!/bin/sh
# Xcode Cloud runs this right after cloning, before it builds. Halo's Xcode project is made from
# project.yml by XcodeGen, so it's made fresh here: always in step with project.yml.
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH/HaloApp"

# Build numbers carry on above the ones the GitHub workflow used (which never reached 1000).
if [ -n "$CI_BUILD_NUMBER" ]; then
  BUILD=$((1000 + CI_BUILD_NUMBER)) perl -pi -e 's/CURRENT_PROJECT_VERSION: "1"/CURRENT_PROJECT_VERSION: "$ENV{BUILD}"/' project.yml
fi
# The team comes from the workflow's secret APPLE_TEAM_ID, so it's never in the repository.
if [ -n "$APPLE_TEAM_ID" ]; then
  perl -pi -e 's/^(\s+)CODE_SIGN_STYLE: Automatic$/$1CODE_SIGN_STYLE: Automatic\n$1DEVELOPMENT_TEAM: "$ENV{APPLE_TEAM_ID}"/' project.yml
fi

brew install xcodegen
xcodegen generate
