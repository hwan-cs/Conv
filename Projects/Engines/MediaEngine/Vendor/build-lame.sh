#!/bin/zsh
# Rebuilds Vendor/LAME.xcframework from LAME 3.100 (LGPL 2.0, see LAME-COPYING.txt).
# LAME is linked dynamically so it can be replaced with a modified build, as the LGPL asks.
#   Source: https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
#   SHA-256: ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
set -euo pipefail
VENDOR=${0:A:h}
WORK=$(mktemp -d)
cd $WORK
curl -sSfL -o lame.tar.gz https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
echo "ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e  lame.tar.gz" | shasum -a 256 -c
tar xzf lame.tar.gz
cd lame-3.100
# 3.100 exports a symbol it no longer defines, which macOS's linker refuses.
sed -i '' '/lame_init_old/d' include/libmp3lame.sym
for arch host in arm64 aarch64-apple-darwin x86_64 x86_64-apple-darwin; do
    make distclean >/dev/null 2>&1 || true
    CFLAGS="-arch $arch -O2 -mmacosx-version-min=14.0" \
    LDFLAGS="-arch $arch -mmacosx-version-min=14.0 -Wl,-install_name,@rpath/libmp3lame.dylib" \
        ./configure --host=$host --prefix=$WORK/$arch --disable-frontend --disable-static --enable-shared --disable-dependency-tracking
    make -j8 && make install
done
mkdir -p $WORK/universal/include
lipo -create $WORK/arm64/lib/libmp3lame.0.dylib $WORK/x86_64/lib/libmp3lame.0.dylib -output $WORK/universal/libmp3lame.dylib
install_name_tool -id @rpath/libmp3lame.dylib $WORK/universal/libmp3lame.dylib
cp $WORK/arm64/include/lame/lame.h $WORK/universal/include/
printf 'module LAME {\n    header "lame.h"\n    link "mp3lame"\n    export *\n}\n' > $WORK/universal/include/module.modulemap
rm -rf $VENDOR/LAME.xcframework
xcodebuild -create-xcframework -library $WORK/universal/libmp3lame.dylib -headers $WORK/universal/include -output $VENDOR/LAME.xcframework
cp COPYING $VENDOR/LAME-COPYING.txt
