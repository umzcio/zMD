# Building zMD for Distribution

## Quick Build (for personal use)

### Option 1: Xcode Archive
1. Open `zMD.xcodeproj` in Xcode
2. Select `Product` → `Archive`
3. Once archived, click `Distribute App`
4. Choose `Copy App`
5. Select a location to save the app
6. The `.app` file can now be moved to `/Applications`

### Option 2: Command Line Build
```bash
# Build Release version
xcodebuild -project zMD.xcodeproj -scheme zMD -configuration Release

# The app will be at:
# build/Release/zMD.app

# Copy to Applications
cp -r build/Release/zMD.app /Applications/
```

### Option 3: Quick Xcode Build
1. In Xcode, select the `zMD` scheme
2. Change build configuration to Release (Product → Scheme → Edit Scheme → Run → Build Configuration → Release)
3. Product → Build (⌘B)
4. Product → Show Build Folder in Finder
5. Navigate to `Products/Release/zMD.app`
6. Drag to `/Applications`

## Running the App

After building:
```bash
# Run directly
open /Applications/zMD.app

# Or double-click the app in Applications folder
```

## First Launch

On first launch, macOS may show a security warning since the app isn't signed. To bypass:
1. Right-click the app → `Open`
2. Click `Open` in the security dialog
3. Or go to System Settings → Privacy & Security → Click "Open Anyway"

## Features

- ✅ Open and view markdown files (.md, .markdown)
- ✅ Tab support for multiple files
- ✅ Outline sidebar (toggle with sidebar icon)
- ✅ Tables, code blocks, headings, lists, checkboxes
- ✅ Right-click context menu on tabs
- ✅ Keyboard shortcuts:
  - `⌘O` - Open file
  - `⌘W` - Close current tab
  - `⌃Tab` - Next tab
  - `⌃⇧Tab` - Previous tab
- ⚠️ Text selection (currently limited - in progress)

## Known Issues

- Text selection needs improvement (Cmd+A and drag-to-select not fully working)
- Table formatting may need adjustment for very wide tables

## Next Steps

If you want to distribute to others, you'll need to:
1. Add a Developer ID certificate (requires Apple Developer account)
2. Code sign the app
3. Notarize with Apple
4. Or distribute as source code for users to build themselves
