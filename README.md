# Photo and Video Organization Toolkit

A comprehensive suite of bash scripts for organizing, managing, and maintaining photo and video collections based on EXIF metadata, filenames, and directory structure.

Designed to improve photo and video organization by automating directory structure creation based on EXIF dates. Supports automatic filename date parsing (including FB_IMG/FB_VID unix timestamps and DYTCamera format `YYYY-MM-DD-HH-MM-SS`). Works with both one-time organization and recurring execution via scheduler on NAS (e.g., Synology NAS DS425+).

## Overview

This toolkit contains two complementary utilities:

1. **manage_images.sh** - Organizes photo and video files into a YYYY/MM/DD directory structure
2. **remove_empty_dirs.sh** - Cleans up empty directories left after file organization

For detailed information on how each script works, functionality, and troubleshooting, see [DETAILS.md](DETAILS.md).

## Quick Start

### Installation

```bash
# 1. Make scripts executable (only needed once)
chmod +x manage_images.sh remove_empty_dirs.sh

# 2. Verify ExifTool is present (required dependency, included in repository)
ls Image-ExifTool/exiftool

# 3. Test run — no files are changed (dry-run is the default)
./manage_images.sh /path/to/source /path/to/target
```

> **Directory layout required:**
> ```
> manage_images.sh
> remove_empty_dirs.sh
> Image-ExifTool/
>   exiftool          ← must be here
> ```

### Organize Photos and Videos

```bash
# Test run (analyze only, no changes)
./manage_images.sh ./photos ./organized

# Copy files (keeps originals)
./manage_images.sh --task=copy ./photos ./organized

# Move files (removes originals)
./manage_images.sh --task=move ./photos ./organized

# Skip screenshots and screen-capture files
./manage_images.sh --task=copy --ignoreFile=Screenshot_,Paint_ ./photos ./organized

# Label WhatsApp/Signal/Facebook files with source tag in filename
./manage_images.sh --task=copy --keepSourceTag ./photos ./organized

# Combine: skip screenshots, tag social media, use source labels
./manage_images.sh --task=move \
  --ignoreFile=Screenshot_,Paint_ \
  --keepSourceTag \
  ./photos ./organized
```

### Running from Different Directories

The scripts automatically detect their location and find all dependencies (ExifTool, etc.).

```bash
# Run from script directory
cd /path/to/scripts
./manage_images.sh ./photos ./organized

# Run from any directory using full path
/path/to/scripts/manage_images.sh /home/user/photos /home/user/organized

# Run with custom log directory
LOG_DIR=/var/log/photos /path/to/scripts/manage_images.sh ./photos ./organized

# Full example from any directory
LOG_DIR=/tmp/logs /path/to/scripts/manage_images.sh \
  --task=copy --limit=1000 /mnt/nas/photos /home/user/organized
```

### Clean Up Empty Directories

```bash
# Preview what will be deleted
./remove_empty_dirs.sh ./photos

# Actually delete empty directories
./remove_empty_dirs.sh --delete ./photos
```

## Options

### manage_images.sh

| Option | Default | Description |
|--------|---------|-------------|
| `--task=copy\|move` | dry-run | Action to perform (`copy` keeps originals, `move` removes them) |
| `--limit=N` | all | Process only first N files — useful for testing |
| `--min-year=YYYY` | 1990 | Reject EXIF dates older than this year |
| `--no-fallback-date` | off | Don't use system file modification date when EXIF is missing |
| `--ignoreFile=P1,P2` | — | Skip files whose full path contains any of the given substrings (comma-separated, case-sensitive). Skipped files are not copied/moved and are listed in `log_ignored_files.log`. |
| `--keepSourceTag` | off | Append a source label to the filename for known types (WhatsApp, Signal, Screenshot, etc.). Files with no matching rule stay plain `IMG_`/`VID_`. |

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_DIR` | `.` (current dir) | Directory where log subdirectories are created |

**`--keepSourceTag` — built-in source types:**

| Tag appended | Matched patterns (in full path) |
|---|---|
| `_Screenshot` | `Screenshot_`, `screenshot_`, `Screenshots/` |
| `_WhatsApp` | `-WA`, `WhatsApp`, `Whatsapp`, `whatsapp` |
| `_Signal` | `Signal/`, `signal-` |
| `_Telegram` | `Telegram`, `telegram` |
| `_Messenger` | `Messenger`, `messenger` |
| `_Viber` | `Viber`, `viber` |
| `_Facebook` | `FB_IMG_`, `FB_VID_`, `received_`, `Facebook`, `facebook` |
| `_Wiadomosci` | `Wiadomości/`, `Wiadomosci/`, `Messages/`, `MmsCamera` |
| `_Paint` | `Paint_`, `paint_` |

> Patterns are matched against the **full path** (filename + all directory names).
> Matching is **case-sensitive** and **unicode-sensitive** — `Wiadomości` ≠ `Wiadomosci`.
> To add a custom type, edit `SOURCE_TAG_RULES` at the top of `manage_images.sh`.

**`--ignoreFile` examples:**

```bash
# Skip Android screenshots and Paint files
--ignoreFile=Screenshot_,Paint_

# Skip WhatsApp media and Telegram downloads
--ignoreFile=WhatsApp,Telegram

# Multiple sources — any match causes the file to be skipped
--ignoreFile=Screenshot_,Paint_,IMG-WA,VID-WA
```

> Note: matching is case-sensitive. If files may have mixed case (e.g. after Windows transfer), add both variants: `--ignoreFile=Screenshot_,screenshot_`

### remove_empty_dirs.sh

| Option | Default | Description |
|--------|---------|-------------|
| `--delete` | dry-run | Actually delete empty directories (default is preview only) |
| `--min-depth=N` | 1 | Skip directories shallower than N levels |

---

## Supported Formats

Images: jpg, jpeg, png, gif, bmp, tiff, tif, raw, cr2, nef, arw, dng, heic, heif, webp

Videos: mp4, mov, avi, mkv, wmv, flv, webm, m4v, mpg, mpeg, 3gp, mts, m2ts

## Features

- Prevents simultaneous execution with automatic lock file mechanism
- Organizes logs into dated subdirectories (logs/YYYY_MM_DD_HH_MM_SS/)
- Generates execution status report (status.log) with timing information
- Duplicate detection based on MD5 checksums
- Automatic EXIF date fallback hierarchy with validation
- Detailed logging of all operations (copies, moves, skipped files, errors)
- File path pattern filtering (`--ignoreFile`) to skip screenshots, screen captures, etc.

## Requirements

- Bash shell (Linux/Unix/macOS)
- ExifTool (included in Image-ExifTool/ directory)
- Standard Unix tools: find, md5sum, stat, awk, sed

## Disclaimer

This software is provided "as is" without warranty. Always test with a small sample first. Keep backups of your original files. Use --limit=10 or --limit=100 for initial testing.

## Recurring Execution (Synology NAS Example)

For automated recurring organization on Synology NAS, create a custom script and schedule it via Task Scheduler:

```bash
#!/bin/bash
cd /volume1/scripts
bash /volume1/scripts/manage_images.sh --task=move --limit=20000 /volume1/IMPORTER /volume1/photo/ARCHIVES
```

Then schedule this script to run periodically (e.g., daily, weekly) via Synology's Task Scheduler.

## Documentation

- [DETAILS.md](DETAILS.md) - Detailed specifications, workflows, and technical information
- [README.md](README.md) - This file (quick reference)

## License

Provided as-is for personal use. No warranty or support provided.
