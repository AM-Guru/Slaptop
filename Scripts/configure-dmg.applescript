-- Copyright © 2026 Kalani Helekunihi and AM Guru, LLC.
-- This source code is licensed under the MIT License. See LICENSE for details.

on run arguments
    if (count of arguments) is not 1 then error "Expected the mounted disk-image path."

    set mountPath to item 1 of arguments
    set mountedAlias to POSIX file mountPath as alias

    -- Finder occasionally stops responding on the long-lived release runner.
    -- Bound the optional presentation work so it cannot block publication.
    with timeout of 30 seconds
        tell application "Finder"
            set mountedDisk to disk of mountedAlias
            tell mountedDisk
                open
                set diskWindow to container window
                set current view of diskWindow to icon view
                set toolbar visible of diskWindow to false
                set statusbar visible of diskWindow to false
                set bounds of diskWindow to {160, 120, 820, 520}

                set viewOptions to icon view options of diskWindow
                set arrangement of viewOptions to not arranged
                set icon size of viewOptions to 112
                set text size of viewOptions to 13
                set label position of viewOptions to bottom
                set background picture of viewOptions to file ".background:background.png"

                set position of item "Slaptop.app" to {170, 210}
                set position of item "Applications" to {490, 210}
                set extension hidden of item "Slaptop.app" to true

                update without registering applications
                delay 2
                close diskWindow
            end tell
        end tell
    end timeout
end run
