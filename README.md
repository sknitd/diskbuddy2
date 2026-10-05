# DiskBuddy (SwiftUI recreation)

A native macOS disk-space app modelled on the DiskBuddy walkthrough video and diskbuddy.com.
Not affiliated with diskbuddy.com.

Nine rooms: Overview, Space, Cleanup, Duplicates, Applications, Monitor, Activity, Find, Compress.
Everything runs locally. Cleanup moves items to the Trash; nothing is deleted outright.

## Build

Requires macOS 14+ and the Swift toolchain (Xcode or Command Line Tools).

```bash
./scripts/build_app.sh   # produces DiskBuddy.app (ad-hoc signed)
open DiskBuddy.app
```

A prebuilt arm64 `DiskBuddy.app` is included. Because it is ad-hoc signed, the first launch may need
right-click → Open.

Setting `DISKBUDDY_SNAPSHOT=<dir>` makes the app save PNGs of its own tabs (developer aid).
