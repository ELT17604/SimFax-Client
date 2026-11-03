#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/.build/tests" "$ROOT/.build/module-cache"
# Extract the diagnostic value type unchanged, excluding the App entry point.
printf 'import Foundation\n' > "$ROOT/.build/tests/Exchange.swift"
sed -n '/^struct Exchange: Identifiable {/,/^@MainActor final class ConsoleWindow/ p' "$ROOT/Sources/SimuFax.swift" | sed '$d' >> "$ROOT/.build/tests/Exchange.swift"
xcrun swiftc -module-cache-path "$ROOT/.build/module-cache" -parse-as-library -o "$ROOT/.build/tests/checks" "$ROOT/Tests/DiagnosticsChecks.swift" "$ROOT/.build/tests/Exchange.swift"
"$ROOT/.build/tests/checks"
