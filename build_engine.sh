#!/bin/sh
set -e
SDK=/opt/ios-sdks/iPhoneOS16.5.sdk
RT=$(find /usr/lib -name "libclang_rt.builtins-aarch64.a" | head -1)
FW="-F$SDK/System/Library/Frameworks -F$SDK/System/Library/PrivateFrameworks"
SRC=$1; OUT=$2
clang -target arm64-apple-ios15.0 -isysroot $SDK -O1 -fobjc-arc -fobjc-runtime=ios-15.0 $FW -c $SRC -o /tmp/$OUT.o 2>&1 | grep -E "error" || true
ld64.lld -arch arm64 -platform_version ios 15.0 16.5 -syslibroot $SDK -o $OUT /tmp/$OUT.o $RT $FW \
  -framework Foundation -framework CoreFoundation -framework NetworkExtension \
  -framework BackBoardServices -framework MobileCoreServices -framework CoreServices \
  -lobjc -lSystem -e _main -undefined dynamic_lookup 2>&1 | grep -E "error|undefined" | head -5
echo "--- deps ---"; llvm-otool -L $OUT | tail -n +2
