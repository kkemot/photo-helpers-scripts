# Photo and Video Organization Toolkit

A comprehensive suite of bash scripts for organizing, managing, and maintaining photo and video collections based on EXIF metadata, filenames, and directory structure.

Designed to improve photo and video organization by automating directory structure creation based on EXIF dates. Supports both one-time organization and recurring execution via scheduler on NAS (e.g., Synology NAS DS425+).

## Overview

This toolkit contains two complementary utilities:

1. **manage_images.sh** - Organizes photo and video files into a YYYY/MM/DD directory structure
2. **remove_empty_dirs.sh** - Cleans up empty directories left after file organization

For detailed information on how each script works, functionality, and troubleshooting, see [DETAILS.md](DETAILS.md).

## Quick Start

### Organize Photos and Videos

```bash
# Test run (analyze only, no changes)
./manage_images.sh ./photos ./organized

# Copy files (keeps originals)
./manage_images.sh --task=copy ./photos ./organized

# Move files (removes originals)
./manage_images.sh --task=move ./photos ./organized
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

