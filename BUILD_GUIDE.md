# BUILD_GUIDE.md — AntiFreeze in Xcode, baby steps

> Do **one step at a time**. Don't skip ahead. If Xcode yells at you, stop,
> copy the exact red error text, and send it to me verbatim — we'll fix it
> together.

## Step 0 — What you need

- A Mac with Xcode installed (Mac App Store → search "Xcode" → Get).
  If you already did this for the OG Box Scanner build, skip to Step 1.
- The `AntiFreeze/` source folder from this repo (it's next to this guide).

## Step 1 — Create the Xcode project

1. Open **Xcode**.
2. Menu: **File → New → Project…**
3. In the template picker, click the **macOS** tab at the top.
4. Choose **App**, click **Next**.
5. Fill in these exact values:
   - **Product Name:** `AntiFreeze`
   - **Team:** (pick your own Apple team from the dropdown)
   - **Organization Identifier:** `com.luckyclover`
   - **Bundle Identifier:** Xcode will auto-fill `com.luckyclover.antifreeze` — good.
   - **Interface:** `SwiftUI`
   - **Language:** `Swift`
   - **Storage:** `None` (we use raw SQLite, not Core Data)
   - Uncheck **"Include Tests"** (keeps it simple for v1).
6. Click **Next**, choose a folder (e.g. `~/Projects/`), click **Create**.

## Step 2 — Remove Xcode's starter files

Xcode generated two files we are replacing with our own:

1. In the left sidebar (Project Navigator), find **`AntiFreezeApp.swift`** — right-click it → **Delete** → **Move to Trash**.
2. Find **`ContentView.swift`** — right-click → **Delete** → **Move to Trash**.

(We delete them because our repo ships its own `AntiFreezeApp.swift`. Keeping
both would be a duplicate-name compile error.)

## Step 3 — Add the AntiFreeze source

1. In Finder, open this repo's **`AntiFreeze/`** folder (the one containing
   `AntiFreezeApp.swift`, `Models/`, `MonitoringEngine/`, etc.).
2. Drag that **`AntiFreeze` folder** into Xcode's Project Navigator, dropping
   it right under the blue `AntiFreeze` project icon.
3. A dialog appears. Check these boxes:
   - ✅ **Copy items if needed**
   - ✅ **Create groups**
   - ✅ Under "Add to targets": **AntiFreeze** checked.
4. Click **Finish**.

You should now see `Models/`, `MonitoringEngine/`, `Storage/`, `Permissions/`,
`Privacy/`, `Dashboard/` groups in Xcode.

## Step 4 — Make it a menu-bar-only app (no dock icon)

1. Click the blue **AntiFreeze** project icon at the very top of the sidebar.
2. Click the **AntiFreeze** target underneath it.
3. Click the **Info** tab at the top.
4. Hover over any row → click the **+** that appears → in the key dropdown,
   type `Application is agent (UIElement)` and set its value to **YES**.
   (This is `LSUIElement` — it hides the dock icon so the app lives only
   in the menu bar.)

## Step 5 — Set the macOS version

1. Still on the target, click the **General** tab.
2. Under **Minimum Deployments**, set **macOS** to **13.0**.

## Step 6 — Link frameworks, set the bridging header, then build

The code uses three Apple frameworks Xcode doesn't link by default, plus
one C header Swift can't see on its own. Do this **before** you build —
it prevents three guaranteed red errors.

**Part A — link the three frameworks (60 seconds):**

1. Click the blue **AntiFreeze** project icon → **AntiFreeze** target →
   **Build Phases** tab.
2. Open **Link Binary With Libraries** → click the **+** button.
3. In the search box type `IOKit.framework` → select it → **Add**.
4. Click **+** again → type `UserNotifications.framework` → select → **Add**.
5. Click **+** again → type `libsqlite3.tbd` → select → **Add**.
6. All three should now be in the list. (If one was already there, skip
   it — no harm done.)

**Part B — point Xcode at the bridging header:**

The process-list collector uses `proc_pidinfo`, which lives in a C-only
header Swift can't see without help. The header file shipped with the
source (it came along when you dragged the folder in).

1. Still on the **AntiFreeze** target, click the **Build Settings** tab.
2. In the search box at the top-right of Build Settings, type `bridging`.
3. Find **Objective-C Bridging Header** (under "Swift Compiler – General").
4. Double-click its value field and type exactly:
   `AntiFreeze/AntiFreeze-Bridging-Header.h`
5. Press **Enter**.

**Part C — build:**

1. Press **⌘B** (or menu **Product → Build**).
2. Wait. The first build takes a minute or two.

**Any red error:** stop, copy the exact text, send it to me verbatim.

## Step 7 — Run

1. Press **⌘R** (or menu **Product → Run**).
2. Look at your **menu bar** (top-right): a ❄️ **snowflake icon** should appear.
3. Click it → a popover shows live CPU, memory pressure, thermal, disk,
   and process readings. Numbers update every few seconds.
4. On first launch, a **Permissions** window also opens — walk through it
   (or skip; telemetry works without the grants).

## Step 8 — What "working" looks like

- The snowflake stays in the menu bar; quitting is via Activity Monitor
  (it's a menu-bar agent, so there's no dock icon to right-click — v1
  simplicity, a Quit button comes with the Phase 9 dashboard).
- Open **Console.app** and filter for `AntiFreeze`: you'll see one-time
  notes for any metric your hardware doesn't expose (e.g. GPU on some
  Macs). That's the graceful-degradation working as designed — not an error.
- Telemetry is stored at
  `~/Library/Application Support/AntiFreeze/telemetry.db`
  (SQLite — you can peek with `sqlite3` in Terminal if you're curious).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Snowflake never appears | Check Xcode's run console for a crash log; send it to me |
| Popover says "Collecting first samples…" forever | The engine didn't start — check Console.app for AntiFreeze errors |
| "Permission denied" reading `/Library/Logs/DiagnosticReports` | Expected without Full Disk Access — grant it in the Permissions window |

That's Phase 1. Nothing else gets built until this runs clean on your Mac.
