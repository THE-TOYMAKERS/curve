#!/bin/zsh
# Run from a logged-in macOS desktop session. Native WebKit checks start Apple's
# rendering helpers; restricted command sandboxes can prevent those helpers.
set -euo pipefail
cd "$(dirname "$0")"
CHECK_ROOT="$PWD/.build/checks"
mkdir -p "$CHECK_ROOT/module-cache"
export CLANG_MODULE_CACHE_PATH="$CHECK_ROOT/module-cache"
common=(-parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$CHECK_ROOT/module-cache")
core_link=(-I "$CHECK_ROOT" -L "$CHECK_ROOT" -lBrowserCore -Xlinker -rpath -Xlinker @executable_path)

swiftc "${common[@]}" -emit-library -emit-module -module-name BrowserCore Sources/BrowserCore/*.swift \
  -o "$CHECK_ROOT/libBrowserCore.dylib" -emit-module-path "$CHECK_ROOT/BrowserCore.swiftmodule" \
  -Xlinker -install_name -Xlinker @rpath/libBrowserCore.dylib
swiftc "${common[@]}" "${core_link[@]}" Tests/BrowserCoreTests/*.swift -o "$CHECK_ROOT/core-checks"
"$CHECK_ROOT/core-checks"

if [[ -f Checks/KeyboardRouterChecks.swift ]]; then
  swiftc "${common[@]}" Sources/Curve/KeyboardRouter.swift Checks/KeyboardRouterChecks.swift -o "$CHECK_ROOT/keyboard-checks"
  "$CHECK_ROOT/keyboard-checks"
fi

for name in EngineSmoke EnginePrivate; do
  swiftc "${common[@]}" Sources/Curve/WebEngine.swift "Checks/$name.swift" -o "$CHECK_ROOT/$name"
  "$CHECK_ROOT/$name"
done

app_sources=(Sources/Curve/*.swift)
app_sources=("${(@)app_sources:#Sources/Curve/CurveApp.swift}")
for pair in "StoreIntegration:store-integration" "ShortcutActionChecks:shortcut-actions" "DragChecks:drag-checks"; do
  source_name="${pair%%:*}"
  executable_name="${pair#*:}"
  if [[ -f "Checks/$source_name.swift" ]]; then
    swiftc "${common[@]}" "${core_link[@]}" "${app_sources[@]}" "Checks/$source_name.swift" -o "$CHECK_ROOT/$executable_name"
    "$CHECK_ROOT/$executable_name" "$CHECK_ROOT"
  fi
done
print "All browser checks passed."
