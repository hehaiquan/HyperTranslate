#!/bin/bash
set -euo pipefail

# 运行定向测试，将编译缓存限制在项目目录中。
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
export CLANG_MODULE_CACHE_PATH="$PROJECT_ROOT/.cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_ROOT/.cache/swift-modules"
swift test --disable-sandbox --cache-path .cache/swiftpm \
    --config-path .cache/swiftpm/config --security-path .cache/swiftpm/security
