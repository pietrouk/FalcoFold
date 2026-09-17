#!/bin/bash
# Builds a Release FalcoFold.app with an ad-hoc signature and zips it into dist/.
# Ad-hoc signing needs no Apple account, but macOS ties the Screen Recording
# permission to the signature, so every new build asks for it again.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)
APP=build/Build/Products/Release/FalcoFold.app
ZIP="dist/FalcoFold-$VERSION.zip"

xcodegen generate
xcodebuild -project FalcoFold.xcodeproj -scheme FalcoFold -configuration Release \
    -derivedDataPath build -quiet \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    build

codesign --verify --deep --strict "$APP"
mkdir -p dist
rm -f "$ZIP"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
echo "Built $ZIP"
