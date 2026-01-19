#!/bin/bash

# Build script for cloudflared mobile library
# This script builds the Go library for Android using gomobile

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
FLUTTER_PLUGIN_DIR="$PROJECT_ROOT/flutter_plugin/cloudflared_tunnel"
BUILD_DIR="$SCRIPT_DIR/build"

# Ensure Go and gomobile are in PATH
export PATH="/usr/local/go/bin:$HOME/go/bin:$PATH"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Cloudflared Mobile Build Script ===${NC}"
echo ""

# Check for required tools
check_tool() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "${RED}Error: $1 is not installed${NC}"
        echo "Please install $1 first"
        exit 1
    fi
}

check_tool go

# Install gomobile if not available
if ! command -v gomobile &> /dev/null; then
    echo -e "${YELLOW}Installing gomobile...${NC}"
    go install golang.org/x/mobile/cmd/gomobile@latest
    go install golang.org/x/mobile/cmd/gobind@latest
fi

# Ensure submodule is initialized
if [ ! -f "$PROJECT_ROOT/cloudflared/go.mod" ]; then
    echo -e "${YELLOW}Initializing cloudflared submodule...${NC}"
    cd "$PROJECT_ROOT"
    git submodule update --init --recursive
fi

# Create build directory
mkdir -p "$BUILD_DIR"

# Initialize gomobile if needed
echo -e "${YELLOW}Initializing gomobile...${NC}"
gomobile init 2>/dev/null || true

# Ensure mobile/bind is available
go get golang.org/x/mobile/bind 2>/dev/null || true

build_android() {
    echo -e "${GREEN}Building Android AAR...${NC}"

    cd "$SCRIPT_DIR"

    # Build AAR with gomobile
    gomobile bind -v \
        -target=android \
        -androidapi=21 \
        -o "$BUILD_DIR/cloudflared.aar" \
        -ldflags="-s -w" \
        .

    if [ -f "$BUILD_DIR/cloudflared.aar" ]; then
        echo -e "${GREEN}✓ Android AAR built successfully: $BUILD_DIR/cloudflared.aar${NC}"

        # Extract AAR for Flutter plugin
        extract_aar_for_flutter
    else
        echo -e "${RED}✗ Failed to build Android AAR${NC}"
        exit 1
    fi
}

extract_aar_for_flutter() {
    echo -e "${YELLOW}Extracting AAR for Flutter plugin...${NC}"

    FLUTTER_ANDROID_DIR="$FLUTTER_PLUGIN_DIR/android"
    AAR_FILE="$BUILD_DIR/cloudflared.aar"

    if [ ! -d "$FLUTTER_ANDROID_DIR" ]; then
        echo -e "${RED}Flutter plugin directory not found: $FLUTTER_ANDROID_DIR${NC}"
        echo -e "${YELLOW}Skipping Flutter plugin extraction${NC}"
        return
    fi

    # Create temp directory for extraction
    TEMP_DIR=$(mktemp -d)

    # Extract AAR
    unzip -q "$AAR_FILE" -d "$TEMP_DIR"

    # Create libs directory if not exists
    mkdir -p "$FLUTTER_ANDROID_DIR/libs"

    # Copy classes.jar
    if [ -f "$TEMP_DIR/classes.jar" ]; then
        cp "$TEMP_DIR/classes.jar" "$FLUTTER_ANDROID_DIR/libs/cloudflared-classes.jar"
    fi

    # Copy JNI libs
    if [ -d "$TEMP_DIR/jni" ]; then
        rm -rf "$FLUTTER_ANDROID_DIR/src/main/jniLibs"
        cp -r "$TEMP_DIR/jni" "$FLUTTER_ANDROID_DIR/src/main/jniLibs"
    fi

    # Cleanup
    rm -rf "$TEMP_DIR"

    echo -e "${GREEN}✓ Extracted to Flutter plugin:${NC}"
    echo "    - $FLUTTER_ANDROID_DIR/libs/cloudflared-classes.jar"
    echo "    - $FLUTTER_ANDROID_DIR/src/main/jniLibs/"
}

build_ios() {
    echo -e "${GREEN}Building iOS Framework...${NC}"

    cd "$SCRIPT_DIR"

    # Build iOS framework with gomobile
    gomobile bind -v \
        -target=ios \
        -o "$BUILD_DIR/Cloudflared.xcframework" \
        -ldflags="-s -w" \
        .

    if [ -d "$BUILD_DIR/Cloudflared.xcframework" ]; then
        echo -e "${GREEN}✓ iOS Framework built successfully: $BUILD_DIR/Cloudflared.xcframework${NC}"
    else
        echo -e "${RED}✗ Failed to build iOS Framework${NC}"
        exit 1
    fi
}

# Parse arguments
case "${1:-android}" in
    android)
        build_android
        ;;
    ios)
        build_ios
        ;;
    all)
        build_android
        build_ios
        ;;
    *)
        echo "Usage: $0 [android|ios|all]"
        exit 1
        ;;
esac

echo ""
echo -e "${GREEN}Build complete!${NC}"
echo ""
echo "Output files:"
if [ -f "$BUILD_DIR/cloudflared.aar" ]; then
    echo "  - $BUILD_DIR/cloudflared.aar"
fi
if [ -d "$BUILD_DIR/Cloudflared.xcframework" ]; then
    echo "  - $BUILD_DIR/Cloudflared.xcframework"
fi
