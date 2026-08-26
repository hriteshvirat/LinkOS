import re

path = "/Users/hritesh/.gemini/antigravity-ide/scratch/LinkOS/macOS/LinkOS/UI/PhoneMirroring/PhoneBottomBar.swift"
with open(path, "r") as f:
    text = f.read()

# Replace showControlsPopover with workspace.showControlsPopover in specific lines:
# 1. showControlsPopover.toggle()
text = text.replace("showControlsPopover.toggle()", "workspace.showControlsPopover.toggle()")
# 2. showControlsPopover = false
text = text.replace("showControlsPopover = false", "workspace.showControlsPopover = false")
# 3. showControlsPopover = true
text = text.replace("showControlsPopover = true", "workspace.showControlsPopover = true")
# 4. value: showControlsPopover
text = text.replace("value: showControlsPopover", "value: workspace.showControlsPopover")

# Fix $showDevDiagnostics
text = text.replace("$showDevDiagnostics", "$workspace.showDevDiagnostics")

# We already made sendControlMessage public in PhoneSession, so `await session.sendControlMessage` should now work!

with open(path, "w") as f:
    f.write(text)
