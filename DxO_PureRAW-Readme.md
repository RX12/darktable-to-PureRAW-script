# DxO_PureRAW (darktable 5.6 ↔ DxO PureRAW 6)

Integrates **DxO PureRAW 6** (https://www.dxo.com/dxo-pureraw/) into **darktable 5.6** (Lua API 9.7.0, Lua 5.4) on Windows 10/11 and macOS 14+.

From the lighttable, this script sends selected camera RAW files to DxO PureRAW 6, watches a dedicated staging folder for the processed outputs (DNG, TIFF, JPEG), moves them next to the source RAW files so they land in the **same film roll**, and imports them into darktable — optionally grouped with the original RAW (as group leader) and with copied tags, metadata, and extra tags.

## Requirements

- **darktable 5.6** or newer (ships with bundled `lua-scripts` utilities `lib/dtutils*`).
- **DxO PureRAW 6** (also compatible with PureRAW 4 / 5 using the same staging-folder workflow).
- No external LuaRocks (`luafilesystem` is not required).

## Setup

### 1. Enable the script in darktable

Place `DxO_PureRAW.lua` in your darktable Lua scripts folder (`$CONFIGDIR/lua/workflow-scripts/`) using `./deploy.sh` and load it via `luarc` (`require "workflow-scripts/DxO_PureRAW"`) or enable it through darktable's **script_manager** module.

### 2. Configure darktable Preferences → Lua Options

- **DxO PureRAW 6 executable**:
  - **Windows**: `C:\Program Files\DxO\DxO PureRAW 6\PureRawv6.exe`
  - **macOS**: `/Applications/DxO PureRAW 6.app` (selecting either the `.app` bundle or the inner binary inside `Contents/MacOS/` is supported)
- **DxO PureRAW staging folder**:
  - Choose a dedicated **empty** folder where PureRAW will write its output files before darktable moves them into the source image's folder.
- **DxO PureRAW timeout per image (mins)**:
  - Maximum idle wait time per image (1–30 minutes, default `2`). The timer resets each time an image finishes processing.

### 3. Configure DxO PureRAW 6 Export Settings (in-app)

Because DxO PureRAW has no CLI flags, output settings are configured inside PureRAW's processing dialog:

- **Output Format**: **DNG (standard linear DNG)** or **TIFF** (and optionally **JPEG** alongside DNG).
  - **IMPORTANT:** Do **NOT** select PureRAW 6's **"High-Fidelity compressed DNG"** (DNG 1.7 / JPEG XL). darktable 5.6 cannot read JPEG XL-compressed DNGs and `dt.database.import()` will fail.
- **Destination**: **Custom folder** → select the exact same **Staging Folder** configured in darktable's Lua Options.
- **File Renaming**: Any suffix/naming format where the output filename starts with the original file stem (e.g. `Filename-Processing Method`, custom suffixes, or `_01` duplicate counters).
- **Export to application**: **None** (darktable watches the staging folder and imports results automatically).

## Usage

1. Select one or more camera RAW images in darktable's **lighttable** view.
2. Open the **DxO PureRAW** panel on the right side of the lighttable and choose import options:
   - **group with original**: group the imported image(s) with the source RAW and make the processed DNG/TIFF the group leader.
   - **copy existing tags**: copy user tags from the source RAW (skipping internal `darktable|` tags).
   - **copy metadata**: copy `title`, `description`, `creator`, `publisher`, and `rights`.
   - **extra tags**: optional comma-separated tags to create and attach on import.
3. Click **Process with DxO PureRAW**.
4. Confirm and start processing inside the DxO PureRAW 6 window.
5. Watch progress in darktable's background jobs panel (or click **Cancel Waiting** / the job's cancel button to abort cleanly). When files finish writing and stabilize in the staging folder, darktable moves them next to the source RAWs and imports them into the current film roll.
