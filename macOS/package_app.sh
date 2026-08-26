#!/bin/bash

# Define paths
APP_NAME="LinkOS"
EXECUTABLE_PATH=".build/apple/Products/Release/LinkOS"
APP_BUNDLE_PATH="build/${APP_NAME}.app"
CONTENTS_PATH="${APP_BUNDLE_PATH}/Contents"
MACOS_PATH="${CONTENTS_PATH}/MacOS"
RESOURCES_PATH="${CONTENTS_PATH}/Resources"
APPLICATIONS_DIR="/Applications"

# Create the .app directory structure
mkdir -p "${MACOS_PATH}"
mkdir -p "${RESOURCES_PATH}"

# Copy the executable
cp "${EXECUTABLE_PATH}" "${MACOS_PATH}/${APP_NAME}"

# Copy the existing Info.plist
cp "LinkOS/App/Info.plist" "${CONTENTS_PATH}/Info.plist"

# Copy any resources if they exist (SwiftPM bundles resources next to the executable)
# cp -R .build/apple/Products/Release/*.bundle "${RESOURCES_PATH}/" 2>/dev/null

# Install to /Applications
cp -R "${APP_BUNDLE_PATH}" "${APPLICATIONS_DIR}/"
echo "Installed ${APP_NAME}.app to ${APPLICATIONS_DIR}/"
codesign -s - --force --deep "${APPLICATIONS_DIR}/${APP_NAME}.app"
