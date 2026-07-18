#!/bin/zsh

set -euo pipefail

SRCROOT=$(realpath "$1")
TARGET_IPA=$2

WORKSPACE="$SRCROOT/Asspp.xcworkspace"
SCHEME="Asspp"
BUILD_PRODUCT="Asspp.app"

cd $SRCROOT

BUILD_ARGS=(
    -workspace "$WORKSPACE"
    -scheme "$SCHEME"
    -configuration Release
    -derivedDataPath "$SRCROOT/build/DerivedDataApp"
    -destination 'generic/platform=iOS'
    build
    CODE_SIGN_IDENTITY=""
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_ENTITLEMENTS=""
    CODE_SIGNING_ALLOWED=NO
    GCC_GENERATE_DEBUGGING_SYMBOLS=YES
    STRIP_INSTALLED_PRODUCT=NO
    COPY_PHASE_STRIP=NO
    UNSTRIPPED_PRODUCT=NO
)

if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "${BUILD_ARGS[@]}" | xcbeautify
else
    xcodebuild "${BUILD_ARGS[@]}"
fi

BUILD_PRODUCT_PATH=""
for i in $(find "$SRCROOT/build/DerivedDataApp" -name "$BUILD_PRODUCT")
do
    BUILD_PRODUCT_PATH=$i
    break
done
BUILD_PRODUCT_PATH=$(realpath "$BUILD_PRODUCT_PATH")

if [ -z "$BUILD_PRODUCT_PATH" ]; then
    echo "[-] build product not found"
    exit 1
fi

echo "[+] build product path: $BUILD_PRODUCT_PATH"

echo "[+] packaging..."
pushd "$SRCROOT/build"
mkdir -p Payload
cp -r "$BUILD_PRODUCT_PATH" Payload
zip -r "$TARGET_IPA" Payload
rm -rf Payload
popd

echo "[+] done"
