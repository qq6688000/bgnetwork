#!/bin/sh
set -e
SDK=/opt/ios-sdks/iPhoneOS16.5.sdk
RT=$(find /usr/lib -name "libclang_rt.builtins-aarch64.a" | head -1)
clang -target arm64-apple-ios15.0 -isysroot $SDK -O2 -c src/wd2.c -o /tmp/wd.o 2>&1 | grep -E "error" || true
ld64.lld -arch arm64 -platform_version ios 15.0 16.5 -syslibroot $SDK -o bgnetworkd-wd2 /tmp/wd.o $RT \
  -lSystem -e _main -undefined dynamic_lookup 2>&1 | grep -E "error|undefined" | head -5
echo "--- deps ---"; llvm-otool -L bgnetworkd-wd2 | tail -n +2
ls -l bgnetworkd-wd2
