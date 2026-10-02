-- layout.applescript VOLUME_NAME APP_NAME TITLE_BAR_PT — Finder window layout of the installer disk image, run by
-- scripts/package.sh on the mounted read-write image (Finder writes it into the volume's .DS_Store): icon view without
-- toolbar or status bar, 600x400 pt content (TITLE_BAR_PT: 32 measured on macOS 27) showing .background/background.tiff,
-- icon size 128, the app centred at (160, 190) and the Applications link at (440, 190) in window points.
-- The first run asks for permission to control Finder (System Settings > Privacy & Security > Automation).
on run argv
	set volName to item 1 of argv
	set appName to item 2 of argv
	set titleBar to (item 3 of argv) as integer
	tell application "Finder"
		tell disk volName
			open
			set current view of container window to icon view
			set toolbar visible of container window to false
			set statusbar visible of container window to false
			set bounds of container window to {200, 120, 800, 520 + titleBar}
			set opts to icon view options of container window
			set arrangement of opts to not arranged
			set icon size of opts to 128
			set text size of opts to 13
			set shows item info of opts to false
			set shows icon preview of opts to true
			set background picture of opts to file ".background:background.tiff"
			set position of item appName of container window to {160, 190}
			set position of item "Applications" of container window to {440, 190}
			update without registering applications
			delay 1
			close
			open
			delay 1
		end tell
	end tell
end run
