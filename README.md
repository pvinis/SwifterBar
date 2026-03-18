# SwifterBar

A fast, minimal macOS menu bar app that runs scripts and displays their output. Drop a shell script into a folder, and it shows up in your menu bar.

SwifterBar is a clean rewrite of [SwiftBar](https://github.com/swiftbar/SwiftBar) — same plugin format, fewer bugs, tighter security.

## How it works

1. Create a script in `~/SwifterBar/`
2. Name it `{name}.{interval}.{extension}` — e.g. `cpu.10s.sh`
3. Make it executable
4. SwifterBar runs it on schedule and shows the output in your menu bar

That's it.

## Plugin format

Scripts write to stdout. The first line becomes the menu bar title. Everything after `---` goes in the dropdown menu.

```bash
#!/bin/bash
# ~/SwifterBar/weather.5m.sh

echo "72F"
echo "---"
echo "Sunny with clouds | sfimage=sun.max.fill color=#ff9500"
echo "Open Forecast | href=https://weather.com"
echo "Refresh | refresh=true"
```

### Filename intervals

The middle part of the filename sets how often the script runs:

| Suffix | Meaning      | Example        |
|--------|-------------|----------------|
| `s`    | seconds     | `cpu.10s.sh`   |
| `m`    | minutes     | `mail.5m.py`   |
| `h`    | hours       | `backup.1h.rb` |
| `d`    | days        | `quote.1d.sh`  |

Minimum interval is 5 seconds. Maximum is 24 hours.

### Line parameters

Append parameters to any line with `|`:

```
Display Text | key=value key2=value2
```

**Appearance**

| Parameter | Example | Description |
|-----------|---------|-------------|
| `color` | `#ff0000` or `#ff0000,#00ff00` | Text color (light, dark) |
| `sfimage` | `wifi` | SF Symbol icon |
| `font` | `Menlo` | Font name |
| `size` | `14` | Font size (1–200) |
| `image` | `base64...` | Base64-encoded image |
| `templateImage` | `base64...` | Base64-encoded template image |

**Actions**

| Parameter | Example | Description |
|-----------|---------|-------------|
| `href` | `https://example.com` | Open URL on click |
| `bash` | `/usr/local/bin/notify` | Run command on click |
| `param1`–`paramN` | `--verbose` | Arguments for `bash` command |
| `refresh` | `true` | Re-run the plugin on click |

**Other**

| Parameter | Description |
|-----------|-------------|
| `alwaysVisible=true` | Keep menu bar item visible even with empty output |

### Submenus

Indent with `--` dashes for nesting:

```
Top level
---
Item 1
--Sub-item 1a
--Sub-item 1b
----Deep sub-item
Item 2
```

### Separators

Use `---` for visual separators in the dropdown:

```
echo "Title"
echo "---"
echo "Group 1"
echo "---"
echo "Group 2"
```

## Build from source

Requires **macOS 26** and **Swift 6.2**.

```bash
git clone https://github.com/pvinis/swifterbar.git
cd swifterbar
swift build -c release
```

The binary lands in `.build/release/SwifterBar`.

## Run

```bash
swift run SwifterBar
```

Or copy the built binary somewhere in your `$PATH`.

## Right-click menu

Right-click any SwifterBar item for:

- **Open Plugin Folder** — opens `~/SwifterBar/` in Finder
- **Refresh All** — re-runs every plugin immediately
- **Quit** — exits the app

## Security

SwifterBar takes security seriously:

- Scripts run with **argv arrays** — no shell string interpolation
- Plugin files must be **owned by you** and **executable**
- Symlinks pointing outside the plugin directory are **rejected**
- URLs are restricted to **http/https** only
- Base64 images are capped at **1MB / 1024x1024**
- Script output is limited to **500 lines / 4KB per line**
- Each execution has a **30-second timeout**
- Only essential environment variables are passed to plugins

## Environment variables

Plugins receive these env vars at runtime:

| Variable | Description |
|----------|-------------|
| `SWIFTERBAR_CACHE_DIR` | Cache directory for the plugin |
| `SWIFTERBAR_DATA_DIR` | Data directory for the plugin |
| `SWIFTERBAR_REFRESH_REASON` | Why the plugin was triggered |
| `SWIFTERBAR_APPEARANCE` | Current system appearance (light/dark) |

## License

MIT
