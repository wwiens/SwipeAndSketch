#!/bin/bash
# Builds Vendor/SSKernel.xcframework: the Swipe & Sketch C++ kernel facade (SwipeAndSketch/Kernel)
# statically merged with the Open CASCADE Technology modeling toolkits.
#
#   Scripts/build_kernel.sh            # fetch + build OCCT (first run ~15-30 min), then the facade
#   Scripts/build_kernel.sh --facade   # rebuild only the facade against the existing OCCT build
#   Scripts/build_kernel.sh --occt-only   # OCCT only; ONLY_SDK=iphonesimulator limits it to one slice
#
# Slices: iPadOS device (arm64), iPadOS simulator (arm64 + x86_64, matching the project's Debug
# simulator architectures), macOS (arm64, for `swift test`).
# Only OCCT's FoundationClasses, ModelingData and ModelingAlgorithms modules are built, plus the
# STEP reader (TKDESTEP) and the toolkits it links against (STEP_TOOLKITS): no viewer, FreeType,
# Tcl/Tk, or OpenGL. Adding them to an existing OCCT build compiles only the new toolkits.
set -euo pipefail

OCCT_TAG="V8_0_1"
IOS_MIN="18.0"
MACOS_MIN="14.0"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$ROOT/build/occt"
SRC="$WORK/src"
FACADE="$ROOT/SwipeAndSketch/Kernel"
OUT="$ROOT/Vendor/SSKernel.xcframework"
JOBS="$(sysctl -n hw.ncpu)"

# Toolkits linked into the app, in dependency order.
TOOLKITS=(TKernel TKMath TKG2d TKG3d TKGeomBase TKBRep TKGeomAlgo TKTopAlgo TKPrim TKBO TKBool
          TKShHealing TKFillet TKOffset TKFeat TKMesh TKHLR
          TKDE TKXSBase TKCDF TKLCAF TKCAF TKService TKV3d TKVCAF TKXCAF TKDESTEP)
# STEP import (October 19, 2026): TKDESTEP and what it links against, outside the three modules.
STEP_TOOLKITS="TKDE TKXSBase TKCDF TKLCAF TKCAF TKService TKV3d TKVCAF TKXCAF TKDESTEP"

SLICES=(iphoneos iphonesimulator macosx)
archs() { [[ "$1" == iphonesimulator ]] && echo "arm64 x86_64" || echo "arm64"; }
min_version_flag() {
  case "$1" in
    iphoneos) echo "-mios-version-min=$IOS_MIN" ;;
    iphonesimulator) echo "-mios-simulator-version-min=$IOS_MIN" ;;
    macosx) echo "-mmacosx-version-min=$MACOS_MIN" ;;
  esac
}

fetch_occt() {
  if [[ ! -d "$SRC" ]]; then
    git clone --depth 1 --branch "$OCCT_TAG" https://github.com/Open-Cascade-SAS/OCCT.git "$SRC"
  fi
}

build_occt() {
  local sdk="$1" sysroot install="$WORK/$1" make="$WORK/$1-make"
  sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  local platform_args=()
  case "$sdk" in
    iphoneos|iphonesimulator)
      platform_args=(-D CMAKE_SYSTEM_NAME=iOS -D CMAKE_OSX_DEPLOYMENT_TARGET="$IOS_MIN") ;;
    macosx)
      platform_args=(-D CMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN") ;;
  esac
  mkdir -p "$make"
  cmake -S "$SRC" -B "$make" -G "Unix Makefiles" \
    "${platform_args[@]}" \
    -D CMAKE_OSX_ARCHITECTURES="$(archs "$sdk" | tr ' ' ';')" \
    -D CMAKE_OSX_SYSROOT="$sysroot" \
    -D CMAKE_BUILD_TYPE=Release \
    -D BUILD_LIBRARY_TYPE=Static \
    -D BUILD_RELEASE_DISABLE_EXCEPTIONS=OFF \
    -D INSTALL_DIR="$install" -D INSTALL_DIR_INCLUDE=inc -D INSTALL_DIR_LIB=lib \
    -D BUILD_MODULE_FoundationClasses=ON -D BUILD_MODULE_ModelingData=ON -D BUILD_MODULE_ModelingAlgorithms=ON \
    -D BUILD_MODULE_Visualization=OFF -D BUILD_MODULE_ApplicationFramework=OFF \
    -D BUILD_MODULE_DataExchange=OFF -D BUILD_MODULE_Draw=OFF -D BUILD_MODULE_DETools=OFF \
    -D BUILD_ADDITIONAL_TOOLKITS="$STEP_TOOLKITS" \
    -D USE_FREETYPE=OFF -D USE_TK=OFF -D USE_OPENGL=OFF -D USE_GLES2=OFF -D USE_XLIB=OFF \
    -D USE_FREEIMAGE=OFF -D USE_RAPIDJSON=OFF -D USE_DRACO=OFF -D USE_TBB=OFF -D USE_VTK=OFF \
    -D BUILD_GTEST=OFF -D BUILD_DOC_Overview=OFF -D BUILD_DOC_RefMan=OFF -D BUILD_RESOURCES=OFF \
    > "$WORK/cmake-$sdk.log" 2>&1
  make -C "$make" -j "$JOBS" > "$WORK/make-$sdk.log" 2>&1
  make -C "$make" install > "$WORK/install-$sdk.log" 2>&1
}

build_facade() {
  local sdk="$1" install="$WORK/$1" obj="$WORK/$1-facade"
  local sysroot; sysroot="$(xcrun --sdk "$sdk" --show-sdk-path)"
  rm -rf "$obj"; mkdir -p "$obj"
  for source in "$FACADE"/*.cpp; do
    local arch_flags=()
    for arch in $(archs "$sdk"); do arch_flags+=(-arch "$arch"); done
    xcrun --sdk "$sdk" clang++ -std=c++17 -O2 -fPIC "${arch_flags[@]}" "$(min_version_flag "$sdk")" -isysroot "$sysroot" \
      -Wall -Wno-deprecated-declarations -I "$install/inc" -I "$FACADE/include" \
      -c "$source" -o "$obj/$(basename "${source%.cpp}").o"
  done
  local libs=("$obj"/*.o)
  for toolkit in "${TOOLKITS[@]}"; do libs+=("$install/lib/lib$toolkit.a"); done
  xcrun libtool -static -no_warning_for_no_symbols -o "$obj/libSSKernel.a" "${libs[@]}"
}

if [[ "${1:-}" != "--facade" ]]; then
  fetch_occt
  for sdk in ${ONLY_SDK:-${SLICES[@]}}; do echo "Building OCCT $OCCT_TAG for $sdk…"; build_occt "$sdk"; done
  [[ "${1:-}" == "--occt-only" ]] && exit 0
fi

args=()
for sdk in "${SLICES[@]}"; do
  echo "Building kernel facade for $sdk…"
  build_facade "$sdk"
  args+=(-library "$WORK/$sdk-facade/libSSKernel.a" -headers "$FACADE/include")
done
rm -rf "$OUT"
mkdir -p "$(dirname "$OUT")"
xcodebuild -create-xcframework "${args[@]}" -output "$OUT" > /dev/null
du -sh "$OUT"/*/libSSKernel.a
echo "Created $OUT"
