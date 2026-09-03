# BKSwitcher
BKSwitcher is a macOS Swift utility that builds a random photo collage from your Photos library and sets the collage as your desktop wallpaper.

## Stack
- Swift (Swift Package; open in Xcode if preferred)
- AppKit/Core Image for image processing
- NSImage/CGImage export pipeline (via `NSBitmapImageRep`)
- AppleScript (`osascript`) bridge for wallpaper assignment
- Optional `launchd` LaunchAgent for periodic refresh

## What v1 does
1. Reads image assets from your Photos library.
2. Randomly picks a configurable number of images (default 12).
3. Normalizes orientation via Core Image metadata handling.
4. Renders a dynamic mosaic collage at your current main-monitor resolution with configurable tile gaps.
5. Saves the collage into a cache folder (keeps the latest 6 runs).
6. Sets it as wallpaper with Finder AppleScript.
7. Supports either one-shot run or scheduled refresh.

## Build
```bash
swift build
swift build -c release
```

## Initialize config
```bash
swift run bkswitcher --init-config
```

This creates:
`~/Library/Application Support/BKSwitcher/config.json`

## Example config
```json
{
  "allowDockRestart" : false,
  "allowedExtensions" : [
    "jpg",
    "jpeg",
    "png",
    "heic",
    "heif",
    "tif",
    "tiff"
  ],
  "excludedAlbums" : [
    "Screenshots",
    "Wallpapers"
  ],
  "imageCount" : 12,
  "outputDirectory" : "~/Library/Caches/BKSwitcher",
  "refreshIntervalMinutes" : 60,
  "tileGap" : 6
}
```

Set `excludedAlbums` to Photos album names that should never appear in collages. Matching is case-insensitive and excludes all photos in those albums.
Set `imageCount` to how many photos should be used in each collage.
Set `tileGap` to the pixel gap between photo tiles.
Set `allowDockRestart` to `true` only if you need the legacy `desktoppicture.db` fallback. It is `false` by default because applying that fallback requires restarting the Dock, and a Dock restart un-minimizes every minimized window. When enabled, BKSwitcher snapshots minimized windows before the restart and re-minimizes them afterwards (this needs Accessibility permission for the host app).

## Minimized windows
Wallpaper updates leave window state alone. BKSwitcher applies wallpapers via NSWorkspace, Finder/System Events AppleScript, and the modern `com.apple.wallpaper` store, none of which touch windows. The Dock is never restarted unless you opt in with `allowDockRestart`.

## Photo path output
Each run writes:
- Wallpaper image: `~/Library/Caches/BKSwitcher/wallpaper-<timestamp>.jpg`
- Photo list file: `~/Library/Caches/BKSwitcher/wallpaper-<timestamp>-photos.txt`
- Exported source images used for that run: `~/Library/Caches/BKSwitcher/used-photos/<timestamp>/...`
- Run manifest used by `-r`: `~/Library/Caches/BKSwitcher/wallpaper-<timestamp>-run.json`
- Wallpaper source rotation files used for System Settings list stability: `~/Library/Caches/BKSwitcher/wallpaper-slots/slot-<1...6>.jpg`

The `-photos.txt` file lists the exact exported file path for each photo used, plus the Photos asset identifier and original filename.
The `-run.json` manifest is the machine-readable record of a run: the ordered photo set, canvas size, tile gap, and the layout seed. Because the mosaic layout is randomized, the seed is what allows `-r` to reproduce a previous collage exactly.
BKSwitcher automatically prunes run artifacts so only the latest 6 timestamped collages/logs/used-photo folders are kept.

## Run modes
Run once:
```bash
swift run bkswitcher
```

Continuous loop:
```bash
swift run bkswitcher --loop
```

Recreate the last run:
```bash
swift run bkswitcher -r
```

`-r` (or `--recreate`) skips random photo selection and rebuilds the most recent collage from the same photos, in the same order, with the same mosaic layout and tile gap.

The photos are always re-exported fresh from the Photos library by asset identifier, so any edits you have made in Photos since the original run (crops, adjustments, filters) are picked up. Photo dates and locations are re-read from the library as well. If nothing about the photos has changed, the result is byte-identical to the original; if a photo was edited, that tile reflects the current version. Photos deleted from the library since the original run are skipped with a warning, and dropping photos changes the tile count so the layout will differ. `-r` cannot be combined with `--loop`.

## LaunchAgent (hourly background refresh)
An example plist is included at:
`launchd/com.david.bkswitcher.plist`

Before loading it:
1. Build release binary (`swift build -c release`).
2. Confirm the binary path in the plist matches your machine.
3. Optionally customize `StartInterval`.

Load:
```bash
launchctl unload ~/Library/LaunchAgents/com.david.bkswitcher.plist 2>/dev/null || true
cp launchd/com.david.bkswitcher.plist ~/Library/LaunchAgents/com.david.bkswitcher.plist
launchctl load ~/Library/LaunchAgents/com.david.bkswitcher.plist
```

## Permissions and first run
- On first photo read, macOS may ask for permission to let the host app (for example Terminal) access your Photos library.
- On first wallpaper update, macOS may ask for permission to let Terminal (or your app host) control Finder and System Events via Apple Events.
- If prompted, allow automation; otherwise wallpaper assignment will fail.
