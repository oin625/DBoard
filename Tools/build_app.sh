#!/bin/bash
# Print the built executable path on stdout; build progress stays on stderr.
set -euo pipefail

dboard_project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$dboard_project_dir"

if [ "$#" -gt 1 ]; then
    echo "用法: bash Tools/build_app.sh [--full]" >&2
    exit 2
fi
case "${1:-}" in
    "")
        # Keep -O runtime optimization. A persistent, separate cache lets Swift
        # rebuild changed files and their dependencies instead of optimizing
        # all source files together on every local update.
        # Swift 6.4's default swiftbuild engine does not reliably support this
        # override; its supported native engine does. --full stays available.
        dboard_build_args=(--build-system native --scratch-path .build/fast-release-native
            -c release --product DBoard -j "${DBOARD_BUILD_JOBS:-4}"
            -Xswiftc -no-whole-module-optimization -Xswiftc -incremental)
        ;;
    --full)
        dboard_build_args=(--scratch-path .build -c release --product DBoard)
        ;;
    --help|-h)
        echo "用法: bash Tools/build_app.sh [--full]"
        echo "默认: 本机增量 Release 构建；--full: 默认构建器的整模块 Release 构建。"
        exit 0
        ;;
    *)
        echo "用法: bash Tools/build_app.sh [--full]" >&2
        exit 2
        ;;
esac

# The editor is an offline resource, rebuilt only when its inputs change.
(
    cd "$dboard_project_dir/Tools/ExcalidrawEditor"
    if [ ! -f node_modules/esbuild/package.json ]; then
        npm ci --registry=https://registry.npmjs.org --no-audit --no-fund --progress=false
    fi
    node build.mjs
) >&2

swift build "${dboard_build_args[@]}" >&2
dboard_binary_dir="$(swift build "${dboard_build_args[@]}" --show-bin-path)"
dboard_binary_path="$dboard_binary_dir/DBoard"
if [ ! -x "$dboard_binary_path" ]; then
    echo "未找到 DBoard 构建产物: $dboard_binary_path" >&2
    exit 1
fi
printf '%s\n' "$dboard_binary_path"
