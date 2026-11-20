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
4. Renders a collage at your current main-monitor resolution, using either of two layouts (see below).
5. Saves the collage into a cache folder (keeps the latest 6 runs).
6. Sets it as wallpaper with Finder AppleScript.
7. Supports either one-shot run or scheduled refresh.

## Collage layouts
Two collage layouts are available, selected by the `useOptimalCollageLayout` config flag:
- **Optimal layout** (`useOptimalCollageLayout: true`, the default): a scattered, collage-style arrangement. The canvas is recursively partitioned into randomly-sized cells so every region of the screen gets a photo; each photo then starts at a random size and position inside its cell and is nudged/grown toward open space, so pictures don't line up in rows or columns. Photos are never cropped and keep their original proportions. Each photo gets a white margin (`pictureMarginPixels`, default 15) hugging its own edges, and framed photos always stay at least `pictureSpacingPixels` (default 10) apart so borders never touch. The date (`MM/DD/YYYY`) and location are printed in small black text inside the white margin (date above the photo, location below) rather than over the photo itself.
- **Legacy mosaic layout** (`useOptimalCollageLayout: false`): recursively splits the canvas into randomly-sized rects and crops each photo to fill its rect exactly, separated by `tileGap` pixels of black background.

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

## See the photos in the current background
```bash
swift run bkswitcher --current-images
```

Opens a window with a thumbnail grid of every photo used in the most recent collage (the current background), each with its filename, date taken, and location. Click a photo (or its description) to copy its file name to the clipboard. Right-click for **Open in Photos**, **Open Exported Copy**, or **Show in Finder**. **Open Collage** opens the full collage image. Photos are read from the run's exported copies, so this window does not need Photos library access.

## Edit settings in a window
```bash
swift run bkswitcher --config
```

Opens a settings window showing every option below, with a short description of each. **Save** validates the values, writes them to `config.json`, and closes the window; **Cancel** (or closing the window) discards changes. If the config file doesn't exist yet, the window starts from the defaults and Save creates it.

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
  "pictureMarginPixels" : 15,
  "pictureSpacingPixels" : 10,
  "refreshIntervalMinutes" : 60,
  "tileGap" : 6,
  "useOptimalCollageLayout" : true
}
```

Set `excludedAlbums` to Photos album names that should never appear in collages. Matching is case-insensitive and excludes all photos in those albums.
Set `imageCount` to how many photos should be used in each collage.
Set `useOptimalCollageLayout` to `true` (default) for the proportion-preserving justified layout, or `false` for the legacy cropped mosaic layout.
Set `pictureMarginPixels` to the white margin drawn around each photo in the optimal layout (also where the date/location text is printed).
Set `pictureSpacingPixels` to the minimum black gap between neighboring framed photos in the optimal layout (default 10).
Set `tileGap` to the pixel gap between photo tiles in the legacy mosaic layout.
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

The `-photos.txt` file lists the exact exported file path for each photo used, plus the Photos asset identifier, original filename, and a `libraryUrl` deep link.
The `-run.json` manifest is the machine-readable record of a run: the ordered photo set, canvas size, tile gap, picture margin, picture spacing, which layout was used, and the layout seed. Because layout ordering is randomized, the seed is what allows `-r` to reproduce a previous collage exactly.

## Opening a photo in the Photos app
Every photo entry records a `libraryUrl` of the form:
```
photos://asset?identifier=<UUID>
```
Opening it jumps straight to that photo in the macOS Photos app:
```bash
open "photos://asset?identifier=DCB2A15F-220B-4354-BA59-341DD3A78F38"
```

The `photos` scheme is registered by Photos.app (alongside `photos-navigation` and `cloudphoto`). The UUID is the leading segment of the Photos asset identifier: identifiers look like `<UUID>/L0/001`, and only the UUID belongs in the URL.

List every link from the latest run:
```bash
grep libraryUrl ~/Library/Caches/BKSwitcher/wallpaper-*-photos.txt
```

An AppleScript alternative also works and additionally brings Photos to the front:
```bash
osascript -e 'tell application "Photos" to spotlight media item id "<UUID>/L0/001"'
```
Note that this one takes the *full* identifier including the `/L0/001` suffix, unlike the URL. There is no way to produce a link that opens a specific photo on another machine or on the web; these identifiers are local to your library. Sharing a photo externally requires an iCloud share link created from the Photos UI.
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

`-r` (or `--recreate`) skips random photo selection and rebuilds the most recent collage from the same photos, in the same order, with the same layout, tile gap/picture margin/picture spacing, and layout seed.

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
