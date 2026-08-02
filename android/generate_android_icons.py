import os
import subprocess

source_icon = "/Users/hritesh/.gemini/antigravity-ide/brain/16b41634-6cdb-4fa9-b85e-5d6f28db497b/linkos_official_brand_icon_1785077200012.png"
res_dir = "/Users/hritesh/.gemini/antigravity-ide/scratch/LinkOS/android/app/src/main/res"
tool_path = "/Users/hritesh/.gemini/antigravity-ide/scratch/LinkOS/android/IconResizer"

# Compile swift helper tool if needed
subprocess.run(["swiftc", "-O", "/Users/hritesh/.gemini/antigravity-ide/scratch/LinkOS/android/IconResizer.swift", "-o", tool_path], check=True)

densities = {
    "mipmap-mdpi": (48, 108),
    "mipmap-hdpi": (72, 162),
    "mipmap-xhdpi": (96, 216),
    "mipmap-xxhdpi": (144, 324),
    "mipmap-xxxhdpi": (192, 432)
}

if not os.path.exists(source_icon):
    print(f"Source icon not found: {source_icon}")
    exit(1)

for folder, (size, fg_size) in densities.items():
    target_dir = os.path.join(res_dir, folder)
    os.makedirs(target_dir, exist_ok=True)
    
    # Standard Launcher Icons (Zoomed out 18% so circle/squircle masks don't clip edges)
    for name in ["ic_launcher.png", "ic_launcher_round.png", "ic_app_logo.png", "ic_app_logo_round.png"]:
        path = os.path.join(target_dir, name)
        subprocess.run([tool_path, source_icon, path, str(size), "0.82"], check=True)
        
    # Adaptive Foreground Icons (Zoomed out 40% to fit within Android 66% inner safe zone)
    for name in ["ic_launcher_foreground.png", "ic_app_logo_foreground.png"]:
        path = os.path.join(target_dir, name)
        subprocess.run([tool_path, source_icon, path, str(fg_size), "0.60"], check=True)

print("✅ All Android icon assets generated successfully with 40% adaptive safe-zone zoom!")
