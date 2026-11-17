#!/bin/zsh
# Builds Conv in Release, signed with Developer ID, and packs it into dist/Conv.dmg
# with an Applications shortcut to drag it onto.
set -euo pipefail

root=${0:A:h:h}
build=$root/dist/build
staging=$root/dist/staging
dmg=$root/dist/Conv.dmg

cd $root
tuist generate --no-open
xcodebuild build \
    -workspace Conv.xcworkspace \
    -scheme Conv \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath $build \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    PROVISIONING_PROFILE_SPECIFIER= \
    OTHER_CODE_SIGN_FLAGS="--timestamp" \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    | grep -E "error:|BUILD"

app=$build/Build/Products/Release/Conv.app
codesign --verify --deep --strict $app

rm -rf $staging $dmg
mkdir -p $staging
cp -R $app $staging/
ln -s /Applications $staging/Applications
hdiutil create \
    -volname Conv \
    -srcfolder $staging \
    -format UDZO \
    -ov \
    $dmg
rm -rf $staging
echo $dmg
