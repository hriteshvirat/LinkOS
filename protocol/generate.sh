#!/bin/bash
# LinkOS Protocol Buffer Code Generation Script
# Generates Swift and Kotlin code from .proto files.
#
# Prerequisites:
#   brew install protobuf swift-protobuf
#   (Kotlin codegen handled by Gradle plugin)
#
# Usage: ./generate.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROTO_DIR="$SCRIPT_DIR"

# Output directories
SWIFT_OUT="$SCRIPT_DIR/../macOS/LinkOS/Core/Protocol/Generated"
KOTLIN_OUT="$SCRIPT_DIR/../android/app/src/main/kotlin/com/linkos/core/protocol/generated"

echo "🔧 LinkOS Protocol Buffer Code Generation"
echo "=========================================="
echo ""

# Ensure output directories exist
mkdir -p "$SWIFT_OUT"
mkdir -p "$KOTLIN_OUT"

# ---- Swift Generation ----
echo "📦 Generating Swift code..."
if command -v protoc-gen-swift &> /dev/null; then
    for proto_file in "$PROTO_DIR"/*.proto; do
        filename=$(basename "$proto_file")
        echo "  → $filename"
        protoc \
            --proto_path="$PROTO_DIR" \
            --swift_out="$SWIFT_OUT" \
            --swift_opt=Visibility=Public \
            "$proto_file"
    done
    echo "✅ Swift generation complete: $SWIFT_OUT"
else
    echo "⚠️  protoc-gen-swift not found. Install with: brew install swift-protobuf"
    echo "   Skipping Swift generation."
fi

echo ""

# ---- Kotlin Generation ----
echo "📦 Generating Kotlin code..."
echo "   Kotlin generation is handled by the Gradle protobuf plugin."
echo "   Run './gradlew generateProto' in the android/ directory."

echo ""
echo "=========================================="
echo "✅ Protocol generation complete!"
echo ""
echo "Proto files processed:"
for proto_file in "$PROTO_DIR"/*.proto; do
    echo "  • $(basename "$proto_file")"
done
