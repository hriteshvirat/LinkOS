#!/usr/bin/env python3
import os
import shutil
import subprocess
import sys

def main():
    android_dir = os.path.dirname(os.path.abspath(__file__))
    java_home = "/Applications/Android Studio.app/Contents/jbr/Contents/Home"
    env = os.environ.copy()
    env["JAVA_HOME"] = java_home
    env["PATH"] = f"{java_home}/bin:{env.get('PATH', '')}"

    print("Building real LinkOS Android APK via Gradle...")
    cmd = ["./gradlew", "assembleDebug"]
    res = subprocess.run(cmd, cwd=android_dir, env=env)

    if res.returncode != 0:
        print("❌ Gradle build failed!")
        sys.exit(1)

    apk_source = os.path.join(android_dir, "app", "build", "outputs", "apk", "debug", "app-debug.apk")
    apk_target = "/Users/hritesh/Downloads/LinkOS.apk"

    if not os.path.exists(apk_source):
        print(f"❌ APK output not found at {apk_source}")
        sys.exit(1)

    shutil.copy2(apk_source, apk_target)
    size_bytes = os.path.getsize(apk_target)
    size_mb = size_bytes / (1024 * 1024)
    print(f"✅ Real signed APK successfully generated and saved to {apk_target} ({size_bytes} bytes / {size_mb:.2f} MB)!")

if __name__ == "__main__":
    main()
