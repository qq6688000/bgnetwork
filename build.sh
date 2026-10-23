#!/bin/sh
set -e
SDK=/opt/ios-sdks/iPhoneOS16.5.sdk
RT=$(find /usr/lib -name "libclang_rt.builtins-aarch64.a" | head -1)
FW="-F$SDK/System/Library/Frameworks -F$SDK/System/Library/PrivateFrameworks"
mkdir -p out; cd out
SRC=$1; OUT=$2
for arch in arm64 arm64e; do
  clang -target $arch-apple-ios15.0 -isysroot $SDK -O1 -fobjc-arc -fobjc-runtime=ios-15.0 $FW -c ../src/$SRC -o $OUT.$arch.o
  ld64.lld -arch arm64 -platform_version ios 15.0 16.5 -syslibroot $SDK -o $OUT.$arch \
    $OUT.$arch.o $RT $FW -framework Foundation -lobjc -lSystem -e _main -undefined dynamic_lookup
  python3 - <<PY
import struct
p="$OUT.$arch"
if "arm64e" in p:
    d=bytearray(open(p,'rb').read())
    if len(d)>12 and d[:4]==b'\xcf\xfa\xed\xfe':
        struct.pack_into('<I',d,8,0x80000002)
        open(p,'wb').write(d)
PY
done
python3 /tmp/bgn17/mkfat.py arm64 $OUT.arm64 arm64e $OUT.arm64e $OUT
python3 - <<PY
import struct
p="$OUT"
d=bytearray(open(p,'rb').read())
n=struct.unpack('>I',d[4:8])[0]
for i in range(n):
    e=8+20*i
    if struct.unpack('>I',d[e+4:e+8])[0]==0x80000002: struct.pack_into('>I',d,e+4,2)
open(p,'wb').write(d)
PY
ls -l $OUT
