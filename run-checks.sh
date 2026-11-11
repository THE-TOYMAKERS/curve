#!/bin/zsh
# Run from a logged-in macOS desktop session. Native WebKit checks start Apple's
# rendering helpers; restricted command sandboxes can prevent those helpers.
set -euo pipefail
cd "$(dirname "$0")"
CHECK_ROOT="$PWD/.build/checks"
mkdir -p "$CHECK_ROOT/module-cache"
rm -rf "$CHECK_ROOT/Protection"
cp -R Resources/Protection "$CHECK_ROOT/Protection"
export CLANG_MODULE_CACHE_PATH="$CHECK_ROOT/module-cache"
common=(-parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" -module-cache-path "$CHECK_ROOT/module-cache")
core_link=(-I "$CHECK_ROOT" -L "$CHECK_ROOT" -lBrowserCore -Xlinker -rpath -Xlinker @executable_path)

swiftc "${common[@]}" -emit-library -emit-module -module-name BrowserCore Sources/BrowserCore/*.swift \
  -o "$CHECK_ROOT/libBrowserCore.dylib" -emit-module-path "$CHECK_ROOT/BrowserCore.swiftmodule" \
  -Xlinker -install_name -Xlinker @rpath/libBrowserCore.dylib
swiftc "${common[@]}" "${core_link[@]}" Tests/BrowserCoreTests/*.swift -o "$CHECK_ROOT/core-checks"
"$CHECK_ROOT/core-checks"

swiftc "${common[@]}" "${core_link[@]}" Checks/PrivacyStorageChecks.swift -o "$CHECK_ROOT/privacy-storage"
"$CHECK_ROOT/privacy-storage"
swiftc "${common[@]}" Sources/BrowserCore/URLSecurity.swift Checks/URLSecurityChecks.swift -o "$CHECK_ROOT/url-security"
"$CHECK_ROOT/url-security"
./Checks/ReleaseSecurityChecks.sh

engine_sources=(Sources/Curve/WebEngine.swift Sources/Curve/WebDocumentRetirement.swift Sources/Curve/ContentProtection.swift Sources/Curve/PrivacySettings.swift)
swiftc "${common[@]}" "${core_link[@]}" Sources/Curve/ContentProtection.swift Checks/ProtectionChecks.swift -o "$CHECK_ROOT/protection-checks"
"$CHECK_ROOT/protection-checks" "$PWD/Resources/Protection"

if [[ -f Checks/KeyboardRouterChecks.swift ]]; then
  swiftc "${common[@]}" Sources/Curve/KeyboardRouter.swift Checks/KeyboardRouterChecks.swift -o "$CHECK_ROOT/keyboard-checks"
  "$CHECK_ROOT/keyboard-checks"
fi

for name in EngineSmoke EnginePrivate WebEngineSecurityChecks; do
  swiftc "${common[@]}" "${core_link[@]}" "${engine_sources[@]}" "Checks/$name.swift" -o "$CHECK_ROOT/$name"
  if [[ "$name" == WebEngineSecurityChecks ]]; then "$CHECK_ROOT/$name" "$PWD/Resources/Protection"; else "$CHECK_ROOT/$name"; fi
done

app_sources=(Sources/Curve/*.swift)
app_sources=("${(@)app_sources:#Sources/Curve/CurveApp.swift}")
for pair in "StoreIntegration:store-integration" "ShortcutActionChecks:shortcut-actions" "DragChecks:drag-checks" "PrivacyIntegrationChecks:privacy-integration"; do
  source_name="${pair%%:*}"
  executable_name="${pair#*:}"
  if [[ -f "Checks/$source_name.swift" ]]; then
    swiftc "${common[@]}" "${core_link[@]}" "${app_sources[@]}" "Checks/$source_name.swift" -o "$CHECK_ROOT/$executable_name"
    "$CHECK_ROOT/$executable_name" "$CHECK_ROOT"
  fi
done
print "All browser checks passed."
