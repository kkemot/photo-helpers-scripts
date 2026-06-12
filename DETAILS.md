# Detailed Documentation

Complete reference for both scripts in the Photo and Video Organization Toolkit.

## Table of Contents

- [manage_images.sh](#manage_imagesh)
- [remove_empty_dirs.sh](#remove_empty_dirsh)
- [Processing Workflows](#processing-workflows)
- [Testing Guide](#testing-guide)
- [Troubleshooting](#troubleshooting)
- [Performance Notes](#performance-notes)

---

## manage_images.sh

Organizes photo and video files into a YYYY/MM/DD directory structure based on EXIF metadata and filename patterns.

### Features

- Extracts dates from EXIF metadata (DateTimeOriginal, CreateDate, MediaCreateDate, etc.)
- Parses dates from filenames when EXIF is missing or invalid
- Automatically writes parsed dates back to EXIF tags for future reliability
- Validates dates (rejects common errors like 1970-01-01)
- Handles duplicate files using MD5 checksums
- Supports both images and videos (25+ formats)
- Generates detailed logs for all operations
- Dry-run mode for safe testing
- Real-time progress display
- Copy or move operations

### Installation

```bash
chmod +x manage_images.sh
```

ExifTool is auto-downloaded into the `Image-ExifTool/` directory on first run
if missing (set `NO_AUTO_DOWNLOAD=1` to disable). A pre-existing system
`exiftool` on `$PATH` is also accepted by `test_manage_images.sh` if the
bundled binary is absent.

### Syntax

```bash
./manage_images.sh [OPTIONS] <source_directory> <target_directory>
```

### Options

| Option | Description |
|--------|-------------|
| `--limit=N` | Process only first N files (useful for testing) |
| `--task=ACTION` | Action: `copy` or `move` (default: dry-run) |
| `--min-year=YYYY` | Minimum valid year for dates (default: 1990) |
| `--no-fallback-date` | Don't use system file modification date as fallback |
| `--ignoreFile=P1,P2` | Skip files whose full path contains any of the given substrings (comma-separated). Matched before EXIF analysis — ignored files are not copied/moved and are logged to `log_ignored_files.log`. Matching is **case-sensitive** and strips leading/trailing spaces from each pattern. Example: `--ignoreFile=Screenshot_,Paint_,WhatsApp`. By default the script also skips Synology photo cache thumbnails matching `SYNOPHOTO_THUMB_`. |
| `--keepSourceTag` | Append a source label (`_WhatsApp`, `_Signal`, `_Screenshot`, etc.) to the generated filename for known source types. Files with no matching rule stay plain `IMG_`/`VID_`. Rules are defined in `SOURCE_TAG_RULES` at the top of the script. |
| `-h, --help` | Display help message |

### Usage Examples

```bash
# Test run - analyze only, no changes
./manage_images.sh ./photos ./organized

# Test with limited files
./manage_images.sh --limit=10 ./photos ./organized

# Copy files (keeps originals)
./manage_images.sh --task=copy ./photos ./organized

# Move files (removes originals)
./manage_images.sh --task=move ./photos ./organized

# Process only photos from year 2000 onwards
./manage_images.sh --task=copy --min-year=2000 ./photos ./organized

# Exclude files without valid EXIF dates
./manage_images.sh --task=copy --no-fallback-date ./photos ./organized

# Skip screenshots and screen-capture files (case-sensitive substring match on full path)
./manage_images.sh --task=copy --ignoreFile=Screenshot_,Paint_ ./photos ./organized

# Combine: skip screenshots and only process files with EXIF dates from 2010+
./manage_images.sh --task=copy --min-year=2010 --no-fallback-date --ignoreFile=Screenshot_,Paint_ ./photos ./organized

# Label social media files with source tag in filename
./manage_images.sh --task=copy --keepSourceTag ./photos ./organized

# Full production run: skip screenshots, label social media, logs to /var/log
LOG_DIR=/var/log/photos ./manage_images.sh --task=move \
  --ignoreFile=Screenshot_,Paint_ \
  --keepSourceTag \
  /volume1/IMPORTER /volume1/photo/ARCHIWUM
```

### Date Source Priority

The script attempts to extract dates from multiple sources in this order:

1. DateTimeOriginal (most reliable - original photo capture time)
2. CreateDate (file creation time in EXIF)
3. MediaCreateDate (for video files)
4. TrackCreateDate (alternative video date field)
5. ModifyDate (last modification time in EXIF)
6. Filename Parsing — patterns are tried in this exact order (first match wins):
   1. `FB_IMG_/FB_VID_<unix_ts>` — Facebook shared media (`FB_IMG_1697376732123.jpg`)
   2. `YYYYMMDD_HHMMSS` — Android / Samsung / Pixel (`IMG_`, `VID_`, `PXL_`, `MVIMG_`, `PANO_`, ...)
   3. `YYYYMMDD.HHMMSS` — dot-separated time (`IMG_20231015.143022.jpg`)
   4. `YYYYMMDD-HHMMSS` — Android screenshots (`Screenshot_YYYYMMDD-HHMMSS`)
   5. `YYYY-MM-DD_HH-MM-SS` — some export tools (`photo_2023-10-15_14-30-22.jpg`)
   6. `YYYY-MM-DD-HH-MM-SS` — DYTCamera and similar (`2024-11-21-19-21-29-b09d0.jpg`)
   7. `YYYY-MM-DD-HHMMSS` — Signal messenger (`signal-2023-10-15-143022.jpg`)
   8. `YYYYMMDD` (date only, time = 00:00:00) — WhatsApp (`IMG-20231015-WA0001.jpg`).
      The 8-digit run must be bounded by non-digits (regex anchor added in v3.1)
      so that contiguous strings like `IMG_20231015143022.jpg` (14 digits) are
      NOT mis-parsed as a date.
   - All extracted dates are validated (min_year check) and automatically
     written back to `DateTimeOriginal` + `CreateDate` in EXIF for future runs
     (logged to `log_exif_updates.log`).
7. XMP sidecar file (`filename.xmp` alongside the photo — Adobe, Lightroom, Darktable)
8. Directory path (`YYYY/MM/DD` in path — day-level precision, time = 00:00:00)
9. FileModifyDate (least reliable - system file modification date)

### Processing Flow - File with Valid EXIF Date

```
Input: /photos/vacation.jpg
  |
  v
[Read EXIF Metadata]
  DateTimeOriginal: 2023-07-15 14:30:45
  |
  v
[Validate Date]
  Year >= 1990: YES
  Year <= Current: YES
  |
  v
[Generate Target Path]
  |
  v
Output: /organized/2023/07/15/IMG_20230715_143045.jpg
Result: COPY or MOVE
```

### Processing Flow - File without EXIF Date (Filename Parsing)

```
Input: /photos/DYTCamera/2024/11/2024-11-21-19-21-29-50d99.jpg
  |
  v
[Read EXIF Metadata]
  All dates empty or invalid
  |
  v
[Parse Filename]
  Matched pattern: YYYY-MM-DD-HH-MM-SS (DYTCamera format)
  Extracted: 2024-11-21 19:21:29
  |
  v
[Validate Parsed Date]
  Year >= 1990: YES
  Year <= Current: YES
  |
  v
[Write Date to EXIF]
  DateTimeOriginal = 2024:11:21 19:21:29
  Logged: log_exif_updates.log
  |
  v
[Generate Target Path]
  |
  v
Output: /organized/2024/11/21/IMG_20241121_192129.jpg
Result: COPY or MOVE
```

### Processing Flow - File without Valid Date

```
Input: /photos/unknown.jpg
  |
  v
[Read EXIF Metadata]
  All EXIF dates empty or invalid
  |
  v
[Parse Filename]
  No date pattern recognized
  |
  v
[Fallback Decision]
  --no-fallback-date flag set?
  YES: SKIP file
  NO: Use FileModifyDate (with warning)
  |
  v
Status: SKIP or FileModifyDate (unreliable)
Logged: log_rejected_dates.log
```

### Output Directory Structure

```
target_directory/
├── 2023/
│   ├── 01/
│   │   ├── 15/
│   │   │   ├── IMG_20230115_093045.jpg
│   │   │   ├── IMG_20230115_143022.jpg
│   │   │   └── VID_20230115_180530.mp4
│   │   └── 28/
│   │       └── IMG_20230128_120000.jpg
│   ├── 07/
│   │   └── 04/
│   │       └── IMG_20230704_160000.jpg
│   └── 12/
│       └── 25/
│           └── IMG_20231225_140000.jpg
└── 2024/
    └── 12/
        └── 25/
            └── IMG_20241225_090000.jpg
```

### Log Files Generated

| File | Purpose |
|------|---------|
| `log_processed_files.log` | Successfully copied/moved files |
| `log_skipped_files.log` | Files skipped (duplicates by MD5) |
| `log_failed_files.log` | Files that could not be processed |
| `log_removed_duplicates.log` | Source files removed in move mode |
| `log_rejected_dates.log` | Files with invalid or missing dates |
| `log_exif_updates.log` | Files where dates written to EXIF |
| `log_ignored_files.log` | Files skipped due to `--ignoreFile` pattern match (not copied/moved) |

### Duplicate Handling

The script uses MD5 checksums to detect duplicate files:

- If target file exists with identical content (same MD5): SKIP
- If target file exists but content differs: Rename with suffix `_1`, `_2`, etc.
- In move mode: Source duplicates automatically removed after verification

### Supported Formats

**Images:** jpg, jpeg, png, gif, bmp, tiff, tif, raw, cr2, nef, arw, dng, heic, heif, webp

**Videos:** mp4, mov, avi, mkv, wmv, flv, webm, m4v, mpg, mpeg, 3gp, mts, m2ts

---

## remove_empty_dirs.sh

Finds and removes empty directories left after file organization operations.

### Features

- Identifies truly empty directories (no files at all)
- Identifies directories with only system files (no multimedia)
- Removes hidden system files (.ini, .db, .DS_Store, thumbnails)
- Removes system subdirectories (@eaDir, .thumbnails, etc.)
- Supports preview mode (dry-run)
- Detailed status reporting
- Configurable directory depth

### Installation

```bash
chmod +x remove_empty_dirs.sh
```

### Syntax

```bash
./remove_empty_dirs.sh [OPTIONS] <source_directory>
```

### Options

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview mode - shows what will be deleted (default) |
| `--delete` | Actually delete empty directories |
| `--min-depth=N` | Minimum directory depth to scan (default: 1) |
| `-h, --help` | Display help message |

### Usage Examples

```bash
# Preview mode - what will be deleted
./remove_empty_dirs.sh ./photos

# Actual deletion
./remove_empty_dirs.sh --delete ./photos

# Delete only at depth 2 or more (keep top-level structure)
./remove_empty_dirs.sh --delete --min-depth=2 ./photos

# Help
./remove_empty_dirs.sh --help
```

### What Gets Deleted

1. Completely empty directories (no files)
2. Directories containing only system files:
   - Hidden files: .ini, .db, .DS_Store
   - Thumbnail directories: @eaDir, .thumbnails, .picasaoriginals
   - System directories: #recycle, @Recycle, .synology, @tmp

### What Gets Preserved

- Any directory containing multimedia files (images or videos)
- Directories at depth less than --min-depth

### Processing Flow - Directory Analysis

```
Directory: /photos/2023/01/vacation
  |
  v
[Check for multimedia files]
  Images or videos found?
  YES: KEEP (preserve entire directory tree)
  NO: Continue analysis
  |
  v
[Check for files]
  Any files at all?
  NO: EMPTY - mark for deletion
  YES: Check file types
  |
  v
[Analyze file types]
  Only system files?
  YES: NO_MEDIA - mark for deletion
  NO: KEEP (has user files)
  |
  v
Status: KEEP or DELETE
```

### Deletion Process

1. Lists all empty directories (sorted deepest-first)
2. Removes hidden system files first
3. Removes system subdirectories
4. Uses `rmdir` (fails if directory not empty)
5. Reports failures with reasons

### Example Output - Preview Mode

```
======================================
Finding empty directories
======================================
Source directory:  ./photos
Minimum depth: 1
Mode:              preview (dry-run)

Searching directories...
Found empty directories: 23
Directories with multimedia (kept): 156

Breakdown by type:
  Completely empty:              8 directories
  Only system files:            15 directories

Examples of directories TO DELETE (first 10):
  ./photos/2023/01/15/temp
    → No files
  ./photos/2023/02/old_backups
    → No multimedia files (only system files: 2)
  ...

Examples of KEPT directories (with multimedia, first 20):
  ./photos/2023/01/15/vacation
    → Contains 42 multimedia files
  ./photos/2023/01/16/family
    → Contains 15 multimedia files
  ...

======================================
SUMMARY
======================================
Directories to delete: 23

To actually delete, run with --delete option
======================================
```

### Example Output - Delete Mode

```
======================================
DELETING empty directories
======================================

DELETED: ./photos/2023/01/15/temp
  Reason: No files
DELETED: ./photos/2023/02/old_backups
  (deleted system files and directories)
ERROR: Cannot delete: ./photos/2023/03/mixed
  Contains subdirectories (e.g. subdir)

======================================
SUMMARY
======================================
Deleted:                  22 directories
  (including 8 with hidden system files)
Skipped:                   0 directories
Errors:                    1 directories
======================================
```

### Ignored Directories

These directories and system files are detected and preserved or ignored:

- @eaDir (Synology metadata)
- .picasaoriginals (Google Picasa)
- Picasa (Google Picasa)
- .thumbnails (Linux thumbnails)
- #recycle (Synology recycle)
- @Recycle (Windows recycle)
- .synology (Synology system)
- @tmp (Temporary)
- .DS_Store (macOS metadata)
- desktop.ini (Windows metadata)
- ehthumbs.db (Windows thumbnail cache)
- Thumbs.db (Windows metadata)

---

## Processing Workflows

### Complete Organization Workflow

```
Raw Photo Collection
  |
  v
[manage_images.sh --task=copy]
  - Reads EXIF dates
  - Parses filenames
  - Creates YYYY/MM/DD structure
  - Copies files to organized location
  |
  v
Organized Collection + Logs
  |
  v
[Review log files]
  - Verify processing results
  - Check for rejected dates
  - Identify failed files
  |
  v
[Optional: Verify duplicates]
  - Check log_skipped_files.log
  - Confirm MD5 handling
  |
  v
[remove_empty_dirs.sh --dry-run]
  - Preview empty directories
  - Verify what will be deleted
  |
  v
[remove_empty_dirs.sh --delete]
  - Remove empty directories
  - Clean up system files
  |
  v
Final Organized Collection
```

### Incremental Organization Workflow

```
Large Collection (thousands of files)
  |
  v
[Test with manage_images.sh --limit=10]
  - Quick validation
  - Verify processing logic
  |
  v
[Test with manage_images.sh --limit=100]
  - Check log file generation
  - Verify date extraction variety
  |
  v
[Review logs thoroughly]
  - Check rejected_dates.log
  - Verify EXIF updates
  - Confirm duplicate handling
  |
  v
[Run full manage_images.sh --task=copy]
  - Process all files
  - Generate comprehensive logs
  |
  v
[Run remove_empty_dirs.sh --delete]
  - Clean up source directories
  |
  v
[Full organization complete]
```

---

## Testing Guide

### Initial Safety Testing

Step 1: Analyze first 10 files
```bash
./manage_images.sh --limit=10 /path/to/source /path/to/test
```
Review output statistics and proposed structure.

Step 2: Copy first 10 files
```bash
./manage_images.sh --limit=10 --task=copy /path/to/source /path/to/test
```
Verify files appear in correct YYYY/MM/DD directories.

Step 3: Review all log files

Logs are saved in a timestamped subdirectory: `logs/YYYY_MM_DD_HH_MM_SS/`

```bash
# Find the latest log run
ls -lt logs/ | head -3

# Read logs from the latest run (adjust timestamp)
cat logs/$(ls -t logs/ | head -1)/log_processed_files.log
cat logs/$(ls -t logs/ | head -1)/log_rejected_dates.log
cat logs/$(ls -t logs/ | head -1)/log_exif_updates.log
cat logs/$(ls -t logs/ | head -1)/log_ignored_files.log
```

Step 4: Expand to 100 files
```bash
./manage_images.sh --limit=100 --task=copy /path/to/source /path/to/test
```
Check for patterns in rejected dates and EXIF updates.

Step 5: Inspect results
```bash
find /path/to/test -type f | head -20
tree /path/to/test  # if tree command available
```

Step 6: Full production run (after confirming above)
```bash
./manage_images.sh --task=copy /path/to/source /path/to/organized
```

Step 7: Clean up empty directories
```bash
./remove_empty_dirs.sh --dry-run /path/to/source
./remove_empty_dirs.sh --delete /path/to/source
```

### Validation Checklist

- Verify file count matches expectations
- Check date extraction sources in logs
- Confirm no data loss (same file count before/after)
- Verify MD5 duplicate handling
- Check for unexpected date rejections
- Confirm EXIF updates were applied
- Verify directory structure is correct YYYY/MM/DD

---

## Troubleshooting

### Issue: Many files show FileModifyDate source

Cause: Files lack EXIF dates or recognizable filename patterns.

Solution:
- Use `--no-fallback-date` to identify affected files
- Rename files to include date patterns: IMG_YYYYMMDD_HHMMSS.jpg
- Manually set EXIF dates on original files

### Issue: Files have wrong dates (1970, 1980)

Cause: Camera date was not set when photos taken.

Solution:
- Script auto-rejects dates before --min-year (default: 1990)
- Use filename patterns to provide correct dates
- Set --min-year lower if these dates are intentional

### Issue: Recently copied files have today's date

Cause: FileModifyDate was used as fallback.

Solution:
- If files have date in filename (IMG_20230415.jpg), script will extract it
- Use --no-fallback-date to force filename-only parsing
- Rename files with proper date patterns before organizing

### Issue: Duplicate files handled unexpectedly

Cause: MD5 checksum algorithm or copy behavior.

Solution:
- Check log_skipped_files.log for detected duplicates
- Verify MD5 matching is correct
- Review source and target paths for conflicts

### Issue: Empty directory not deleted

Cause: Contains hidden files, subdirectories, or multimedia files.

Solution:
- Run with --delete in preview first (no flag defaults to --dry-run)
- Check error message for what's blocking deletion
- Verify directory doesn't contain multimedia files
- Manually remove blocking files if necessary

### Issue: Script stops prematurely

Cause: Permission issues, disk space, or path problems.

Solution:
- Check file permissions on source and target
- Verify target directory has write permissions
- Ensure sufficient disk space
- Use absolute paths instead of relative paths
- Check script logs for specific errors

---

## Performance Notes

### Processing Speed

- EXIF reading: ~1 file per second
- File copying: ~5-10 MB/second (depends on storage speed)
- Large batches (5000+ files): 1-2 hours typical
- SSD storage: ~2x faster than HDD

### Optimization Tips

- Use faster storage (SSD) if possible
- Disable filesystem-specific features (SMR, compression)
- Close other applications during processing
- Use NAS local paths instead of remote mounts
- Process in multiple smaller batches if needed

### Resource Usage

- Memory: ~50-100 MB (manageable on all systems)
- CPU: Single-threaded, ~20-40% utilization
- Disk I/O: Primary bottleneck on HDDs
- Network (if remote): Significant impact on speed

### Large Collection Handling

For collections with 100,000+ files:

1. Split into logical groups (by year, camera, etc.)
2. Process each group separately (sequential processing)
3. Merge organized directories afterward

Note: Parallel execution of multiple instances is not supported due to process locking mechanism. Only one instance can run at a time. Process large collections sequentially or split source directories between separate machines/systems if parallel processing is required.

Example:
```bash
# Process year by year (sequential)
./manage_images.sh --task=copy photos_2020/ organized_2020/
./manage_images.sh --task=copy photos_2021/ organized_2021/
./manage_images.sh --task=copy photos_2022/ organized_2022/
```

---

## Additional Notes

### Date Validation

The script rejects dates with these criteria:
- Year < --min-year (default 1990)
- Year > current year
- Month < 1 or > 12
- Day < 1 or > 31
- Hour > 23, Minute > 59, Second > 59

### EXIF Tag Writing

When dates are written to EXIF:
- DateTimeOriginal tag is updated
- CreateDate tag is updated
- ExifTool handles proper formatting
- Original file EXIF is preserved/enhanced

### Symlink Handling

The script:
- Follows symlinks
- Copies through symlinks (doesn't preserve link structure)
- Creates real files in target directory

### Case Sensitivity

File extensions are matched case-insensitively:
- .JPG, .jpg, .Jpg all recognized
- Works correctly on case-sensitive filesystems (Linux)
- Works correctly on case-insensitive filesystems (Windows, macOS)

---

## Version History

### Version 3.1 (June 2026)
- **Auto-download of ExifTool**: when `Image-ExifTool/exiftool` is missing,
  `check_exiftool` now triggers `download_exiftool` which fetches the latest
  release from `https://exiftool.org`, extracts it, verifies it executes,
  and installs it next to the script. Opt-out via `NO_AUTO_DOWNLOAD=1`.
  Requires `curl` or `wget` and `tar`.
- **Performance: single exiftool call per file** (replaces 8 separate
  invocations). `extract_exif_dates` requests all relevant tags
  (`DateTimeOriginal`, `CreateDate`, `MediaCreateDate`, `TrackCreateDate`,
  `ModifyDate`, and three `SubSec*`) in one `-T`-separated batch. Roughly
  8× speedup on EXIF analysis — confirmed by integration test (~2 files/s
  on commodity hardware vs ~0.25 files/s before).
- **Fixed**: hardcoded `./Image-ExifTool/exiftool` in `write_exif_date`
  replaced with `$EXIFTOOL`. Previously, EXIF write-back of filename-parsed
  dates silently failed when the script was run from a directory other than
  its own location.
- **Fixed**: pattern 8 (date-only `YYYYMMDD` parser) is now anchored by
  non-digit boundaries: `(^|[^0-9])([0-9]{8})($|[^0-9])`. Previously a
  filename like `IMG_20231015143022.jpg` (14 contiguous digits) would
  greedily match the first 8 as a date and lose the time portion.
- **Removed dead code**: `get_exif_date()` (~100 lines, never called) and a
  stray `rm -f "$temp_exif_output"` referencing an uninitialised variable.
- **Added**: `test_manage_images.sh` — integration smoke test with 500
  synthetic files across 23 categories, 12 assertions, ~5 min runtime.
  See README → Testing.

### Version 3.0 (May 2026)
- Added `--ignoreFile` option to skip files by path pattern (before EXIF analysis)
- Added `--keepSourceTag` option with configurable `SOURCE_TAG_RULES` table
- Built-in source types: Screenshot, WhatsApp, Signal, Telegram, Messenger, Viber, Facebook, Wiadomosci, Paint
- Extended filename date parsing: Signal (`YYYY-MM-DD-HHMMSS`), WhatsApp date-only (`YYYYMMDD`), dash-separated (`YYYY-MM-DD_HH-MM-SS`)
- Added XMP sidecar file support (Adobe, Lightroom, Darktable)
- Added directory path date fallback (`YYYY/MM/DD` in path)
- Fixed dead code in filename parser (Pattern 2 was unreachable)
- Logs now saved to timestamped subdirectory `logs/YYYY_MM_DD_HH_MM_SS/`

### Version 2.0 (December 2025)
- Added remove_empty_dirs.sh utility
- Enhanced documentation structure
- Improved error messages
- Better handling of system files

### Version 1.0 (Original)
- Initial manage_images.sh release
- Core EXIF and filename parsing
- Duplicate detection via MD5
- Log file generation
