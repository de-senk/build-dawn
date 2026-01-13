#!/bin/bash
set -e
cd "$(dirname "$0")"

# Build architecture
HOST_ARCH=$(uname -m)
if [ "$HOST_ARCH" = "x86_64" ]; then
  HOST_ARCH="x64"
elif [ "$HOST_ARCH" = "aarch64" ]; then
  HOST_ARCH="arm64"
fi

TARGET_ARCH="${1:-$HOST_ARCH}"
if [ "$TARGET_ARCH" != "x64" ] && [ "$TARGET_ARCH" != "arm64" ]; then
  echo "Unknown target \"$TARGET_ARCH\" architecture"
  exit 1
fi

# Dependencies check
command -v git >/dev/null 2>&1    || { echo "ERROR: git not found"; exit 1; }
command -v cmake >/dev/null 2>&1  || { echo "ERROR: cmake not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found"; exit 1; }
command -v ninja >/dev/null 2>&1  || { echo "ERROR: ninja not found"; exit 1; }

# Clone dawn
if [ -z "$DAWN_COMMIT" ]; then
  DAWN_COMMIT=$(git ls-remote https://dawn.googlesource.com/dawn HEAD | awk '{ print $1 }')
fi

if [ ! -d "dawn" ]; then
  git init dawn || exit 1
  git -C dawn remote add origin https://dawn.googlesource.com/dawn || exit 1
fi

git -C dawn fetch --no-recurse-submodules origin "$DAWN_COMMIT" || exit 1
git -C dawn reset --hard FETCH_HEAD || exit 1

if [ -d "dawn/third_party/dxc" ]; then
  git -C dawn/third_party/dxc reset --hard HEAD || exit 1
fi

# Fetch dependencies
python3 dawn/tools/fetch_dawn_dependencies.py --directory dawn || exit 1

# Patches (if needed for Linux)
if [ -f "patches/dawn-static-dxc-lib.patch" ]; then
  git apply -p1 --directory=dawn patches/dawn-static-dxc-lib.patch || true
fi

# Configure dawn build
CMAKE_ARCH_FLAG=""
if [ "$TARGET_ARCH" = "arm64" ] && [ "$HOST_ARCH" = "x64" ]; then
  CMAKE_ARCH_FLAG="-DCMAKE_SYSTEM_PROCESSOR=aarch64 -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++"
fi

cmake \
  -S dawn \
  -B "dawn.build-${TARGET_ARCH}" \
  -G Ninja \
  $CMAKE_ARCH_FLAG \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
  -DDAWN_BUILD_SAMPLES=OFF \
  -DDAWN_BUILD_TESTS=OFF \
  -DDAWN_ENABLE_D3D12=OFF \
  -DDAWN_ENABLE_D3D11=OFF \
  -DDAWN_ENABLE_NULL=OFF \
  -DDAWN_ENABLE_DESKTOP_GL=OFF \
  -DDAWN_ENABLE_OPENGLES=OFF \
  -DDAWN_ENABLE_VULKAN=ON \
  -DDAWN_USE_GLFW=OFF \
  -DDAWN_ENABLE_SPIRV_VALIDATION=OFF \
  -DDAWN_USE_DXC=OFF \
  -DDAWN_USE_BUILT_DXC=OFF \
  -DDAWN_FETCH_DEPENDENCIES=OFF \
  -DDAWN_BUILD_MONOLITHIC_LIBRARY=SHARED \
  -DTINT_BUILD_TESTS=OFF \
  -DTINT_BUILD_SPV_READER=ON \
  -DTINT_BUILD_SPV_WRITER=ON \
  -DTINT_BUILD_CMD_TOOLS=ON \
  -DTINT_BUILD_HLSL_WRITER=OFF \
  -DTINT_BUILD_MSL_WRITER=OFF \
  || exit 1

# Run the full dawn build
cmake --build "dawn.build-${TARGET_ARCH}" --config Release --target webgpu_dawn tint_cmd_tint_cmd --parallel || exit 1

# Prepare output folder
mkdir -p "dawn-${TARGET_ARCH}"
echo "$DAWN_COMMIT" > "dawn-${TARGET_ARCH}/commit.txt"
cp "dawn.build-${TARGET_ARCH}/gen/include/dawn/webgpu.h" "dawn-${TARGET_ARCH}/" || exit 1
cp "dawn.build-${TARGET_ARCH}/libwebgpu_dawn.so" "dawn-${TARGET_ARCH}/" || exit 1
cp "dawn.build-${TARGET_ARCH}/tint" "dawn-${TARGET_ARCH}/" || exit 1

# Done!
if [ -n "$GITHUB_WORKFLOW" ]; then
  # GitHub actions stuff
  tar -czf "dawn-${TARGET_ARCH}-${BUILD_DATE}.tar.gz" "dawn-${TARGET_ARCH}" || exit 1
fi

echo "Build completed successfully!"
