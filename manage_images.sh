#!/bin/bash

# Script for managing and organizing image and video files
# Uses exiftool for metadata analysis

# ====================================
# CONFIGURATION - Base Paths
# ====================================

# Get script directory (where this script is located)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Log directory (where debug logs will be saved)
# Can be overridden by setting LOG_DIR environment variable
LOG_DIR="${LOG_DIR:-.}"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="."

# Lock file (prevents multiple simultaneous runs against the same target directory)
# Use a hash of the canonical destination directory so runs targeting different output
# directories can execute concurrently without colliding.
LOCK_FILE=""

# ====================================
# CONFIGURATION
# ====================================

# Path to exiftool (relative to script directory)
EXIFTOOL="$SCRIPT_DIR/Image-ExifTool/exiftool"

# Image file extensions
IMAGE_EXTENSIONS="jpg jpeg png gif bmp tiff tif raw cr2 nef arw dng heic heif webp"

# Video file extensions
VIDEO_EXTENSIONS="mp4 mov avi mkv wmv flv webm m4v mpg mpeg 3gp mts m2ts"

# File path patterns to ignore (substring match against full path)
# Can be extended at runtime via --ignoreFile=Pattern1,Pattern2
# Default built-in ignore patterns skip Synology photo cache thumbnails.
IGNORE_FILE_PATTERNS=("SYNOPHOTO_THUMB_")

# Known source types for --keepSourceTag.
# Format: "path_pattern:TagLabel" — if the full file path contains path_pattern,
# the TagLabel is appended to the generated filename.
# Patterns are checked in order; first match wins.
# Add or remove entries to customise which sources get labelled.
SOURCE_TAG_RULES=(
    "Screenshot_:Screenshot"
    "screenshot_:Screenshot"
    "Screenshots/:Screenshot"
    "-WA:WhatsApp"
    "WhatsApp:WhatsApp"
    "Whatsapp:WhatsApp"
    "whatsapp:WhatsApp"
    "Signal/:Signal"
    "signal-:Signal"
    "Telegram:Telegram"
    "telegram:Telegram"
    "Messenger:Messenger"
    "messenger:Messenger"
    "Viber:Viber"
    "viber:Viber"
    "FB_IMG_:Facebook"
    "FB_VID_:Facebook"
    "received_:Facebook"
    "Facebook:Facebook"
    "facebook:Facebook"
    "Wiadomości/:Wiadomosci"
    "Wiadomosci/:Wiadomosci"
    "Messages/:Wiadomosci"
    "MmsCamera:Wiadomosci"
    "Paint_:Paint"
    "paint_:Paint"
)

# Whether to append source tag to generated filename (set by --keepSourceTag)
KEEP_SOURCE_TAG="no"

# Directories to skip (Picasa, Synology NAS, etc.)
EXCLUDE_DIRS=(
    "@eaDir"
    ".picasaoriginals" 
    "Picasa"
    ".thumbnails"
    "#recycle"
    "@Recycle"
    ".synology"
    "@tmp"
    ".DS_Store"
    "Thumbs.db"
    "desktop.ini"
    "ehthumbs.db"
)

canonicalize_path() {
    local path="$1"

    if command -v realpath >/dev/null 2>&1; then
        realpath -m "$path" 2>/dev/null || printf '%s' "$path"
    elif command -v readlink >/dev/null 2>&1; then
        readlink -f "$path" 2>/dev/null || printf '%s' "$path"
    else
        if [ -d "$path" ]; then
            (cd "$path" 2>/dev/null && pwd)
        else
            local dir
            dir=$(dirname "$path")
            local base
            base=$(basename "$path")
            if [ -d "$dir" ]; then
                (cd "$dir" 2>/dev/null && printf '%s/%s' "$(pwd)" "$base")
            else
                printf '%s' "$path"
            fi
        fi
    fi
}

set_lock_file() {
    local output_dir="$1"
    local canonical_output
    canonical_output=$(canonicalize_path "$output_dir")
    local lock_hash
    lock_hash=$(printf '%s' "$canonical_output" | md5sum | cut -d' ' -f1)
    LOCK_FILE="/tmp/manage_images_output_${lock_hash}.lock"
}

# ====================================
# FUNCTIONS
# ====================================

# Display help
show_help() {
    cat << EOF
Usage: $0 [OPTIONS] <source_directory> <target_directory>

Script manages and organizes image and video files based on EXIF metadata.
Analyzes files in the source directory and optionally copies/moves them to target directory
organized by date (YYYY/MM/DD structure).

DOCUMENTATION:
    README.md           Quick start guide and overview
    DETAILS.md          Comprehensive technical documentation

ARGUMENTS:
    source_directory    Directory with photos/videos to process
    target_directory    Target directory for organized files

OPTIONS:
    -h, --help              Display this help
    --limit=N               Analyze only first N files (default: all)
    --task=ACTION           Action to perform: copy, move (default: dry-run)
    --no-fallback-date      Don't use system date as fallback (files without EXIF = NONE)
    --min-year=YYYY         Minimum year for EXIF dates (default: 1990)
    --ignoreFile=P1,P2      Skip files whose path contains any of the given substrings
                            (comma-separated, e.g. Screenshot_,Paint_)
    --keepSourceTag         Append a label to the filename for known source types.
                            Only files matching a defined rule receive a tag —
                            unrecognised files stay plain (IMG_.../VID_...).
                            Built-in types: Screenshot, WhatsApp, Signal, Telegram,
                                            Messenger, Viber, Facebook, Wiadomosci, Paint
                            Patterns are matched against the FULL path (filename + dirs).
                            Examples:
                              Screenshot_20230709-113040.png  → IMG_20230709_113040_990_Screenshot.png
                              signal-2023-10-15-143022.jpg    → IMG_20231015_143022_Signal.jpg
                              IMG-20231015-WA0001.jpg         → IMG_20231015_000000_WhatsApp.jpg
                              WhatsApp-2023-10-15-143022.jpg  → IMG_20231015_143022_WhatsApp.jpg
                              FB_IMG_1697376732123.jpg        → IMG_20231015_143022_Facebook.jpg
                              Facebook/IMG_20231015.jpg       → IMG_20231015_000000_Facebook.jpg
                              Messages/photo.jpg              → IMG_20231015_000000_Wiadomosci.jpg
                              IMG_20231003_191232.jpg         → IMG_20231003_191232.jpg  (no tag)

ENVIRONMENT VARIABLES:
    LOG_DIR                 Directory for log files (default: current directory)
                            Example: LOG_DIR=/tmp/photo_logs $0 ./src ./res

SCRIPT PATHS (automatic - work from any directory):
    Script location         Auto-detected: $(dirname "${BASH_SOURCE[0]}")
    ExifTool              Auto-located: ./Image-ExifTool/exiftool (relative to script)
    Log directory         Configurable via LOG_DIR env variable

HOW TO RUN FROM DIFFERENT DIRECTORIES:

  1. Run from script directory (simplest):
     cd /path/to/script
     ./manage_images.sh ./src ./dest

  2. Run from any directory with full paths:
     /path/to/script/manage_images.sh /home/user/photos /home/user/organized

  3. Run from any directory with custom log location:
     LOG_DIR=/var/log/photos /path/to/script/manage_images.sh ./src ./dest

  4. Run with all options from different directory:
     LOG_DIR=/tmp/logs /path/to/script/manage_images.sh \
       --task=copy --limit=1000 --min-year=2015 \
       /mnt/nas/photos /home/user/organized_photos

WORK MODES:
    dry-run             Analysis only, no copying (default)
    copy                Copy files to target directory
    move                Move files to target directory

EXAMPLES:
    # Analysis only (dry-run)
    $0 ./src ./res
    
    # Analysis with custom log directory
    LOG_DIR=/var/log/photo_org $0 ./src ./res
    
    # Analysis with limit
    $0 --limit=10 ./src ./res
    
    # Copying files
    $0 --task=copy ./src ./res
    
    # Moving with limit and minimum year 2000
    $0 --task=move --limit=100 --min-year=2000 ./src ./res
    
    # Skip screenshots and Paint files
    $0 --task=copy --ignoreFile=Screenshot_,Paint_ ./src ./res
    
    # Preserve source label in filename (Screenshot, Signal, WA, etc.)
    $0 --task=copy --keepSourceTag ./src ./res
    
    # Full path, only EXIF > 2010, logs to /tmp
    LOG_DIR=/tmp $0 --task=copy --min-year=2010 /home/user/photos /home/user/output

SUPPORTED EXTENSIONS:
    Images: $IMAGE_EXTENSIONS
    Video:  $VIDEO_EXTENSIONS

SKIPPED DIRECTORIES:
    $(printf '%s, ' "${EXCLUDE_DIRS[@]}" | sed 's/, $//')

SKIPPED FILE PATTERNS (--ignoreFile):
    $([ ${#IGNORE_FILE_PATTERNS[@]} -gt 0 ] && printf '%s, ' "${IGNORE_FILE_PATTERNS[@]}" | sed 's/, $//' || echo "(none)")

EOF
}

# Check if file path matches any of the ignore patterns
# Returns 0 (true) if the file should be ignored, 1 (false) otherwise
should_ignore_file() {
    local file="$1"
    for pattern in "${IGNORE_FILE_PATTERNS[@]}"; do
        if [[ "$file" == *"$pattern"* ]]; then
            return 0
        fi
    done
    return 1
}

# Extract a source tag by matching the full file path against SOURCE_TAG_RULES.
# Returns the TagLabel of the first matching rule, or empty string if no rule matches.
# Only files whose path contains a known pattern receive a tag — all others stay plain.
#
# Examples (with default rules):
#   .../Screenshots/Screenshot_20230709-113040.png  → "Screenshot"
#   .../signal-2023-10-15-143022.jpg                → "Signal"
#   .../IMG-20231015-WA0001.jpg                     → "WhatsApp"
#   .../WhatsApp/IMG_20231015_143022.jpg             → "WhatsApp"
#   .../IMG_20231003_191232.jpg                     → "" (no rule matches → no tag)
#
extract_source_tag() {
    local file="$1"
    for rule in "${SOURCE_TAG_RULES[@]}"; do
        local pattern="${rule%%:*}"
        local tag="${rule##*:}"
        if [[ "$file" == *"$pattern"* ]]; then
            echo "$tag"
            return 0
        fi
    done
    # No rule matched — return empty (no tag appended)
}

# Build find pattern for excluded directories
build_exclude_pattern() {
    local pattern=""
    for dir in "${EXCLUDE_DIRS[@]}"; do
        if [ -z "$pattern" ]; then
            pattern="-path '*/$dir' -prune"
        else
            pattern="$pattern -o -path '*/$dir' -prune"
        fi
    done
    echo "$pattern"
}

# Build pattern for file extensions
build_extension_pattern() {
    local extensions="$1"
    local pattern=""
    
    for ext in $extensions; do
        if [ -z "$pattern" ]; then
            pattern="-iname '*.$ext'"
        else
            pattern="$pattern -o -iname '*.$ext'"
        fi
    done
    
    echo "$pattern"
}

# Download the latest ExifTool release from exiftool.org and install it
# into "$SCRIPT_DIR/Image-ExifTool". Returns 0 on success, 1 on any failure.
#
# Triggered automatically by check_exiftool() when the bundled binary is
# missing. Set NO_AUTO_DOWNLOAD=1 in the environment to disable.
download_exiftool() {
    local target_dir="$SCRIPT_DIR/Image-ExifTool"
    local base_url="https://exiftool.org"

    if [ "${NO_AUTO_DOWNLOAD:-0}" = "1" ]; then
        echo "Auto-download disabled (NO_AUTO_DOWNLOAD=1)."
        return 1
    fi

    echo "ExifTool not found at: $EXIFTOOL"
    echo "Attempting to download the latest release from $base_url ..."

    # Need curl or wget, plus tar
    local fetcher=""
    if command -v curl >/dev/null 2>&1; then
        fetcher="curl"
    elif command -v wget >/dev/null 2>&1; then
        fetcher="wget"
    else
        echo "Error: neither 'curl' nor 'wget' is available — cannot download ExifTool."
        echo "       Install it manually: https://exiftool.org/install.html"
        return 1
    fi
    if ! command -v tar >/dev/null 2>&1; then
        echo "Error: 'tar' is not available — cannot extract ExifTool archive."
        return 1
    fi

    # Resolve latest version from the well-known endpoint
    local version=""
    if [ "$fetcher" = "curl" ]; then
        version=$(curl -fsSL "$base_url/ver.txt" 2>/dev/null | tr -d '[:space:]')
    else
        version=$(wget -qO- "$base_url/ver.txt" 2>/dev/null | tr -d '[:space:]')
    fi
    if [ -z "$version" ]; then
        echo "Error: could not determine latest ExifTool version (no response from $base_url/ver.txt)."
        return 1
    fi
    echo "  Latest version: $version"

    # Download into a temporary directory and only commit on full success
    local tmpdir
    tmpdir=$(mktemp -d 2>/dev/null) || {
        echo "Error: cannot create temporary directory for download."
        return 1
    }
    local tarball="$tmpdir/exiftool.tar.gz"
    local url="$base_url/Image-ExifTool-${version}.tar.gz"

    echo "  Downloading: $url"
    if [ "$fetcher" = "curl" ]; then
        if ! curl -fsSL -o "$tarball" "$url" 2>/dev/null; then
            echo "Error: download failed."
            rm -rf "$tmpdir"
            return 1
        fi
    else
        if ! wget -q -O "$tarball" "$url" 2>/dev/null; then
            echo "Error: download failed."
            rm -rf "$tmpdir"
            return 1
        fi
    fi

    echo "  Extracting..."
    if ! tar -xzf "$tarball" -C "$tmpdir" 2>/dev/null; then
        echo "Error: extraction failed (archive may be corrupt)."
        rm -rf "$tmpdir"
        return 1
    fi

    # Locate the extracted Image-ExifTool-XX.XX/ directory
    local extracted
    extracted=$(find "$tmpdir" -maxdepth 1 -type d -name 'Image-ExifTool-*' 2>/dev/null | head -1)
    if [ -z "$extracted" ] || [ ! -f "$extracted/exiftool" ]; then
        echo "Error: extracted archive does not contain the expected 'exiftool' script."
        rm -rf "$tmpdir"
        return 1
    fi

    # Install: replace any pre-existing Image-ExifTool/ directory atomically-ish
    if [ -d "$target_dir" ]; then
        rm -rf "$target_dir" || {
            echo "Error: cannot remove existing $target_dir (check permissions)."
            rm -rf "$tmpdir"
            return 1
        }
    fi
    if ! mv "$extracted" "$target_dir" 2>/dev/null; then
        echo "Error: cannot install ExifTool to $target_dir (check permissions)."
        rm -rf "$tmpdir"
        return 1
    fi
    chmod +x "$target_dir/exiftool" 2>/dev/null
    rm -rf "$tmpdir"

    # Verify the install actually runs
    if [ ! -x "$target_dir/exiftool" ] || ! "$target_dir/exiftool" -ver >/dev/null 2>&1; then
        echo "Error: ExifTool installed but does not execute (Perl missing or layout invalid)."
        return 1
    fi

    echo "ExifTool $version installed to: $target_dir"
    echo ""
    return 0
}

# Check if exiftool exists; auto-download the latest release if it does not.
check_exiftool() {
    if [ ! -f "$EXIFTOOL" ]; then
        if ! download_exiftool; then
            echo "Error: exiftool not found at $EXIFTOOL and auto-download failed."
            exit 1
        fi
    fi

    # Show exiftool version
    local version
    version=$("$EXIFTOOL" -ver 2>/dev/null)
    if [ -z "$version" ]; then
        echo "Error: $EXIFTOOL is present but cannot execute (Perl missing?)."
        exit 1
    fi
    echo "ExifTool version: $version"
    echo ""
}

# Check if source directory exists
check_source_dir() {
    local src_dir="$1"
    
    if [ ! -d "$src_dir" ]; then
        echo "Error: Source directory '$src_dir' does not exist"
        exit 1
    fi
}

# Calculate MD5 of file
get_file_md5() {
    local file="$1"
    md5sum "$file" 2>/dev/null | cut -d' ' -f1
}

# Generate unique filename if file already exists
generate_unique_path() {
    local target_path="$1"
    local source_file="$2"
    
    # If file doesn't exist, return original path
    if [ ! -f "$target_path" ]; then
        echo "$target_path"
        return 0
    fi
    
    # Check MD5
    local source_md5=$(get_file_md5 "$source_file")
    local target_md5=$(get_file_md5 "$target_path")
    
    # If MD5 are identical, return "SKIP"
    if [ "$source_md5" = "$target_md5" ]; then
        echo "SKIP"
        return 0
    fi
    
    # Files are different - generate unique name with suffix _1, _2, etc.
    local dir=$(dirname "$target_path")
    local filename=$(basename "$target_path")
    local name="${filename%.*}"
    local ext="${filename##*.}"
    
    local counter=1
    while [ -f "${dir}/${name}_${counter}.${ext}" ]; do
        # Check MD5 of next file
        local existing_md5=$(get_file_md5 "${dir}/${name}_${counter}.${ext}")
        if [ "$source_md5" = "$existing_md5" ]; then
            echo "SKIP"
            return 0
        fi
        counter=$((counter + 1))
    done
    
    echo "${dir}/${name}_${counter}.${ext}"
}

# Check if file is video
is_video_file() {
    local file="$1"
    local ext=$(echo "${file##*.}" | tr '[:upper:]' '[:lower:]')
    
    for video_ext in $VIDEO_EXTENSIONS; do
        if [ "$ext" = "$video_ext" ]; then
            return 0
        fi
    done
    return 1
}

# Extract all relevant EXIF date/subsec tags in a SINGLE exiftool invocation.
#
# Rationale: exiftool is a Perl script with significant startup cost (~0.3 s).
# Issuing 8 separate calls per file (one per tag) was the dominant bottleneck;
# batching them into one call cuts EXIF analysis time by roughly 8x.
#
# The function sets the following global variables (read by analyze_exif_dates):
#   EXIF_DATETIME_ORIGINAL, EXIF_SUBSEC_ORIG,
#   EXIF_CREATE_DATE,       EXIF_SUBSEC_DIG,    EXIF_SUBSEC_TIME,
#   EXIF_MEDIA_CREATE,      EXIF_TRACK_CREATE,  EXIF_MODIFY_DATE
#
# Output format from exiftool -T is tab-separated, with '-' as the missing-value
# marker. The order of fields in the output matches the order of -TAG arguments
# on the command line, so positional parsing via `read` is safe.
#
# The fallback hierarchy that consumes these values (DateTimeOriginal →
# CreateDate → MediaCreateDate → TrackCreateDate → ModifyDate → filename →
# XMP → directory path → FileModifyDate) is implemented in process_exif_data.
extract_exif_dates() {
    local file="$1"
    local exif_line

    # -T  : tab-separated single-line output, '-' for missing tags
    # -d  : format applied to date tags only (SubSec tags are unaffected)
    exif_line=$("$EXIFTOOL" -T -d "%Y:%m:%d %H:%M:%S" \
        -DateTimeOriginal -SubSecTimeOriginal \
        -CreateDate -SubSecTimeDigitized -SubSecTime \
        -MediaCreateDate -TrackCreateDate -ModifyDate \
        "$file" 2>/dev/null)

    IFS=$'\t' read -r \
        EXIF_DATETIME_ORIGINAL EXIF_SUBSEC_ORIG \
        EXIF_CREATE_DATE EXIF_SUBSEC_DIG EXIF_SUBSEC_TIME \
        EXIF_MEDIA_CREATE EXIF_TRACK_CREATE EXIF_MODIFY_DATE \
        <<< "$exif_line"

    # Normalize exiftool's missing-value marker '-' to empty string so that
    # downstream `[ -n "$x" ]` checks behave correctly.
    [ "$EXIF_DATETIME_ORIGINAL" = "-" ] && EXIF_DATETIME_ORIGINAL=""
    [ "$EXIF_SUBSEC_ORIG"       = "-" ] && EXIF_SUBSEC_ORIG=""
    [ "$EXIF_CREATE_DATE"       = "-" ] && EXIF_CREATE_DATE=""
    [ "$EXIF_SUBSEC_DIG"        = "-" ] && EXIF_SUBSEC_DIG=""
    [ "$EXIF_SUBSEC_TIME"       = "-" ] && EXIF_SUBSEC_TIME=""
    [ "$EXIF_MEDIA_CREATE"      = "-" ] && EXIF_MEDIA_CREATE=""
    [ "$EXIF_TRACK_CREATE"      = "-" ] && EXIF_TRACK_CREATE=""
    [ "$EXIF_MODIFY_DATE"       = "-" ] && EXIF_MODIFY_DATE=""
}

# Generate proposed new path for file
generate_new_path() {
    local file="$1"
    local date="$2"
    local output_dir="$3"
    
    if [ -z "$date" ]; then
        echo "[NO DATE - cannot generate path]"
        return
    fi
    
    # Remove trailing slash from output_dir
    output_dir="${output_dir%/}"
    
    # Parse date: 2006-12-25 11:30:31 or 2006-12-25 11:30:31.123
    local year=$(echo "$date" | cut -d' ' -f1 | cut -d'-' -f1)
    local month=$(echo "$date" | cut -d' ' -f1 | cut -d'-' -f2)
    local day=$(echo "$date" | cut -d' ' -f1 | cut -d'-' -f3)
    local time_part=$(echo "$date" | cut -d' ' -f2)
    
    # Check if there are milliseconds (format: HH:MM:SS.sss)
    local time=$(echo "$time_part" | cut -d'.' -f1 | tr -d ':')
    local subsec=$(echo "$time_part" | cut -d'.' -f2 -s)
    
    # Determine prefix (IMG or VID)
    local prefix="IMG"
    if is_video_file "$file"; then
        prefix="VID"
    fi
    
    # Get extension
    local ext="${file##*.}"
    
    # Optional source tag (e.g. "Screenshot", "Signal", "WA")
    local tag=""
    if [ "$KEEP_SOURCE_TAG" = "yes" ]; then
        tag=$(extract_source_tag "$file")
    fi
    
    # Generate new name: PREFIX_YYYYMMDD_HHMMSS[_sss][_Tag].ext
    local new_filename
    local tag_suffix=""
    [ -n "$tag" ] && tag_suffix="_${tag}"
    if [ -n "$subsec" ]; then
        local subsec_padded=$(printf "%-3s" "$subsec" | tr ' ' '0')
        new_filename="${prefix}_${year}${month}${day}_${time}_${subsec_padded}${tag_suffix}.${ext}"
    else
        new_filename="${prefix}_${year}${month}${day}_${time}${tag_suffix}.${ext}"
    fi
    
    # Generate full path: output_dir/YYYY/MM/DD/filename
    local new_path="${output_dir}/${year}/${month}/${day}/${new_filename}"
    
    echo "$new_path"
}

# Process files in source directory
scan_files() {
    local src_dir="$1"
    local output_dir="$2"
    local limit="$3"
    local task="$4"
    
    echo "======================================"
    echo "Processing files"
    echo "======================================"
    echo "Script location:   $SCRIPT_DIR"
    echo "ExifTool path:     $EXIFTOOL"
    echo "Log directory:     $LOG_DIR"
    echo "Source directory:  $src_dir"
    echo "Target directory:  $output_dir"
    if [ -n "$limit" ]; then
        echo "File limit:        $limit"
    fi
    if [ -n "$task" ]; then
        echo "Mode:              $task"
    else
        echo "Mode:              dry-run (analysis only)"
    fi
    if [ ${#IGNORE_FILE_PATTERNS[@]} -gt 0 ]; then
        echo "Ignore patterns:   $(IFS=', '; echo "${IGNORE_FILE_PATTERNS[*]}")"
    fi
    if [ "$KEEP_SOURCE_TAG" = "yes" ]; then
        echo "Keep source tag:   yes (source label appended to filename)"
    fi
    echo ""
    echo "Documentation: See README.md and DETAILS.md in script directory for more information"
    echo ""
    
    # Prepare exclusion pattern
    local exclude_pattern=$(build_exclude_pattern)
    
    # Prepare extension pattern
    local all_extensions="$IMAGE_EXTENSIONS $VIDEO_EXTENSIONS"
    local extension_pattern=$(build_extension_pattern "$all_extensions")
    
    # Find all files
    echo "Searching for files..."
    local temp_file=$(mktemp)
    local temp_file_limited=$(mktemp)
    eval "find '$src_dir' $exclude_pattern -o -type f \( $extension_pattern \) -print" > "$temp_file"
    
    # Count all files
    local total_found=$(wc -l < "$temp_file")
    echo "Files found: $total_found"
    
    # Apply limit if set
    local file_count
    if [ -n "$limit" ] && [ "$limit" -gt 0 ] && [ "$total_found" -gt "$limit" ]; then
        head -n "$limit" "$temp_file" > "$temp_file_limited"
        file_count="$limit"
        echo "Limited to:        $limit files"
    else
        cp "$temp_file" "$temp_file_limited"
        file_count="$total_found"
    fi
    
    # Analyze EXIF for selected files
    local temp_exif=$(mktemp)
    local use_fallback="yes"
    [ "$5" = "no-fallback" ] && use_fallback="no"
    local min_year="${6:-1990}"
    analyze_exif_dates "$temp_file_limited" "$temp_exif" "$output_dir" "$use_fallback" "$min_year" "$LOG_SUBDIR"
    
    # Process files (if task is set)
    if [ -n "$task" ] && [ "$task" != "dry-run" ]; then
        local files_to_process=$(grep -c "|OK|" "$temp_exif")
        echo ""
        if [ "$file_count" -gt 0 ]; then
            echo "Files to process: $files_to_process of $file_count analyzed ($(awk "BEGIN {printf \"%.1f\", $files_to_process * 100 / $file_count}")%)"
        else
            echo "Files to process: 0 (no files found)"
        fi
        process_files "$temp_exif" "$task" "$LOG_SUBDIR"
    fi
    
    # Statistics
    display_statistics "$temp_file_limited" "$file_count" "$temp_exif" "$total_found"
    
    # Cleanup
    rm -f "$temp_file" "$temp_file_limited" "$temp_exif"
}

# Analyzes EXIF dates for all files (one by one for accuracy)
analyze_exif_dates() {
    local file_list="$1"
    local output_file="$2"
    local output_dir="$3"
    local use_fallback="$4"
    local min_year="${5:-1990}"
    local log_subdir="${6:-.}"
    local total=$(wc -l < "$file_list")
    
    echo ""
    echo "Analyzing EXIF data..."
    
    # Output file header: file|date|status|new_path|source
    > "$output_file"
    
    # File with rejected dates
    local rejected_log="$log_subdir/log_rejected_dates.log"
    rm -f "$rejected_log"
    
    # File with ignored paths
    local ignored_log="$log_subdir/log_ignored_files.log"
    rm -f "$ignored_log"
    local ignored_count=0
    
    # Process each file individually for accurate EXIF reading
    # This ensures proper date priority and avoids batch parsing issues
    local current=0
    local last_percent=-1
    
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        
        # Skip files matching ignore patterns
        if should_ignore_file "$file"; then
            echo "IGNORED: $file" >> "$ignored_log"
            ignored_count=$((ignored_count + 1))
            total=$((total - 1))
            [ "$total" -eq 0 ] && total=1
            continue
        fi
        
        current=$((current + 1))
        local percent=$((current * 100 / total))
        # Show progress only when percentage changes (reduces output from ~10000 to ~100 lines)
        if [ "$percent" -ne "$last_percent" ]; then
            printf "\rProcessing: %d/%d (%d%%)" "$current" "$total" "$percent"
            last_percent="$percent"
        fi
        
        # Extract all EXIF date/subsec tags in a single exiftool call.
        # Populates EXIF_* globals (see extract_exif_dates for details).
        extract_exif_dates "$file"

        # Process this file with extracted EXIF data
        process_exif_data "$file" "$EXIF_DATETIME_ORIGINAL" "$EXIF_SUBSEC_ORIG" \
            "$EXIF_CREATE_DATE" "$EXIF_SUBSEC_DIG" "$EXIF_SUBSEC_TIME" \
            "$EXIF_MEDIA_CREATE" "$EXIF_TRACK_CREATE" "$EXIF_MODIFY_DATE" \
            "$output_dir" "$output_file" "$use_fallback" "$min_year" "$rejected_log" "$log_subdir"

    done < "$file_list"
    
    # Show information about ignored files
    if [ "$ignored_count" -gt 0 ]; then
        echo ""
        echo "Ignored: $ignored_count files (pattern match, details in $ignored_log)"
    fi
    
    # Show information about rejected dates
    if [ -f "$rejected_log" ]; then
        local rejected_count=$(wc -l < "$rejected_log")
        if [ "$rejected_count" -gt 0 ]; then
            echo ""
            echo "Warning: $rejected_count files without any date (details in $rejected_log)"
        fi
    fi

    echo ""
}

# Parse date from filename (e.g., IMG_20130410_094342.jpg → 2013-04-10 09:43:42)
#
# Supported patterns (in order of precedence):
#  1. FB_IMG_/FB_VID_ unix timestamp — Facebook shared media (`FB_IMG_1697376732123.jpg`)
#  2. YYYYMMDD_HHMMSS  — Android/Samsung (IMG_, VID_, PXL_, MVIMG_, PANO_, etc.)
#  3. YYYYMMDD.HHMMSS  — dot-separated time (`IMG_20231015.143022.jpg`)
#  4. YYYYMMDD-HHMMSS  — Android screenshots (Screenshot_YYYYMMDD-HHMMSS)
#  5. YYYY-MM-DD_HH-MM-SS — some export tools
#  6. YYYY-MM-DD-HH-MM-SS — DYTCamera and other apps (e.g., 2024-11-21-19-21-29)
#  7. YYYY-MM-DD-HHMMSS   — Signal messenger
#  8. YYYYMMDD (date only) — WhatsApp (IMG-YYYYMMDD-WAxxxx), day-resolution fallback
#
parse_date_from_filename() {
    local filename="$1"
    local basename=$(basename "$filename")
    
    local year month day hour min sec
    
    # Pattern 1: FB_IMG_/FB_VID_ unix timestamp (10 or 13 digits)
    # Covers: FB_IMG_1697376732123.jpg, FB_VID_1697376732.mp4
    if [[ "$basename" =~ FB_(IMG|VID)_([0-9]{10,13}) ]]; then
        local ts="${BASH_REMATCH[2]}"
        local seconds="${ts:0:10}"
        local millis="000"
        if [ "${#ts}" -eq 13 ]; then
            millis="${ts:10:3}"
        fi
        local parsed_date
        parsed_date=$(date -d "@$seconds" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
        if [ -n "$parsed_date" ]; then
            if [ "$millis" != "000" ]; then
                echo "${parsed_date}.${millis}"
            else
                echo "$parsed_date"
            fi
            return 0
        fi
    fi

    # Pattern 2: ...YYYYMMDD_HHMMSS... (underscore separator)
    # Covers: IMG_, VID_, PXL_, MVIMG_, PANO_, Screenshot_, bare YYYYMMDD_HHMMSS, etc.
    if [[ "$basename" =~ ([0-9]{8})_([0-9]{6}) ]]; then
        local date_part="${BASH_REMATCH[1]}"
        local time_part="${BASH_REMATCH[2]}"
        year="${date_part:0:4}"; month="${date_part:4:2}"; day="${date_part:6:2}"
        hour="${time_part:0:2}"; min="${time_part:2:2}"; sec="${time_part:4:2}"
        echo "${year}-${month}-${day} ${hour}:${min}:${sec}"
        return 0
    fi

    # Pattern 3: ...YYYYMMDD.HHMMSS... (dot separator)
    # Covers: IMG_20231015.143022.jpg
    if [[ "$basename" =~ ([0-9]{8})\.([0-9]{6}) ]]; then
        local date_part="${BASH_REMATCH[1]}"
        local time_part="${BASH_REMATCH[2]}"
        year="${date_part:0:4}"; month="${date_part:4:2}"; day="${date_part:6:2}"
        hour="${time_part:0:2}"; min="${time_part:2:2}"; sec="${time_part:4:2}"
        echo "${year}-${month}-${day} ${hour}:${min}:${sec}"
        return 0
    fi
    
    # Pattern 4: ...YYYYMMDD-HHMMSS... (dash separator)
    # Covers: Screenshot_YYYYMMDD-HHMMSS (Android), some cameras
    if [[ "$basename" =~ ([0-9]{8})-([0-9]{6}) ]]; then
        local date_part="${BASH_REMATCH[1]}"
        local time_part="${BASH_REMATCH[2]}"
        year="${date_part:0:4}"; month="${date_part:4:2}"; day="${date_part:6:2}"
        hour="${time_part:0:2}"; min="${time_part:2:2}"; sec="${time_part:4:2}"
        echo "${year}-${month}-${day} ${hour}:${min}:${sec}"
        return 0
    fi
    
    # Pattern 5: YYYY-MM-DD_HH-MM-SS (dashes in both date and time parts)
    # Covers: photo_2023-10-15_14-30-22.jpg
    if [[ "$basename" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2})_([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
        echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
        return 0
    fi
    
    # Pattern 6: YYYY-MM-DD-HH-MM-SS (dashes everywhere, DYTCamera format)
    # Covers: 2024-11-21-19-21-29, 2025-07-04-19-01-50-b09d0, etc.
    if [[ "$basename" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{2})-([0-9]{2}) ]]; then
        echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]}"
        return 0
    fi
    
    # Pattern 7: YYYY-MM-DD-HHMMSS (Signal: signal-2023-10-15-143022001.jpg)
    if [[ "$basename" =~ ([0-9]{4})-([0-9]{2})-([0-9]{2})-([0-9]{6}) ]]; then
        local time_part="${BASH_REMATCH[4]}"
        hour="${time_part:0:2}"; min="${time_part:2:2}"; sec="${time_part:4:2}"
        echo "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${hour}:${min}:${sec}"
        return 0
    fi
    
    # Pattern 8: YYYYMMDD date-only (WhatsApp: IMG-20231015-WA0001.jpg)
    # Time is set to 00:00:00 — only day-level precision.
    #
    # IMPORTANT: the 8-digit sequence MUST be bounded by non-digits (start of
    # string / end of string / any non-digit character). Without this anchor,
    # a filename like "IMG_20231015143022.jpg" (14 contiguous digits, no
    # separators) would incorrectly match its first 8 digits and lose the time
    # part. Anchoring forces such concatenated strings to fall through, which
    # is correct: we have no reliable way to know where the date ends and the
    # time begins in an unseparated digit run.
    if [[ "$basename" =~ (^|[^0-9])([0-9]{8})($|[^0-9]) ]]; then
        local date_part="${BASH_REMATCH[2]}"
        year="${date_part:0:4}"; month="${date_part:4:2}"; day="${date_part:6:2}"
        # Basic sanity: month 01-12, day 01-31
        if [[ "$month" =~ ^(0[1-9]|1[0-2])$ ]] && [[ "$day" =~ ^(0[1-9]|[12][0-9]|3[01])$ ]]; then
            echo "${year}-${month}-${day} 00:00:00"
            return 0
        fi
    fi
    
    return 1
}

# Write date to EXIF tags (makes future processing more reliable)
write_exif_date() {
    local file="$1"
    local date="$2"
    local source="$3"
    local exif_log="${4:-./log_exif_updates.log}"
    
    # Convert date format: 2013-04-10 09:43:42 → 2013:04:10 09:43:42
    local exif_date=$(echo "$date" | sed 's/^\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)/\1:\2:\3/')
    
    # Write DateTimeOriginal and CreateDate tags
    # Use the auto-detected $EXIFTOOL path so the script works from any cwd.
    if "$EXIFTOOL" -DateTimeOriginal="$exif_date" -CreateDate="$exif_date" -overwrite_original "$file" >/dev/null 2>&1; then
        echo "[SUCCESS] $file : Added DateTimeOriginal=$exif_date (parsed from $source)" >> "$exif_log"
        return 0
    else
        echo "[FAILED] $file : Could not write DateTimeOriginal=$exif_date" >> "$exif_log"
        return 1
    fi
}

# Validate date - check if correct and not suspiciously old
validate_date() {
    local date="$1"
    local min_year="${2:-1990}"  # Default 1990
    
    # Check if date exists
    [ -z "$date" ] && return 1
    
    # Check date format (YYYY-MM-DD HH:MM:SS)
    if ! [[ "$date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2} ]]; then
        return 1
    fi
    
    # Extract year
    local year=$(echo "$date" | cut -d'-' -f1)
    
    # Reject dates before minimum year (e.g. 1990, 2000)
    # Common wrong dates: 1970-01-01, 1980-01-01 (camera reset)
    if [ "$year" -lt "$min_year" ]; then
        return 1
    fi
    
    # Reject dates in the future
    local current_year=$(date +%Y)
    if [ "$year" -gt "$current_year" ]; then
        return 1
    fi
    
    return 0
}

# Helper function for processing EXIF data of single file
process_exif_data() {
    local full_path="$1"
    local datetime_original="$2"
    local subsec_orig="$3"
    local create_date="$4"
    local subsec_dig="$5"
    local subsec_time="$6"
    local media_create="$7"
    local track_create="$8"
    local modify_date="$9"
    local output_dir="${10}"
    local output_file="${11}"
    local use_fallback="${12}"
    local min_year="${13:-1990}"
    local rejected_log="${14}"
    local log_subdir="${15:-.}"
    
    # Normalize dates from EXIF format (2012:02:04 19:20:30) to ISO (2012-02-04 19:20:30)
    datetime_original=$(echo "$datetime_original" | sed 's/^\([0-9]\{4\}\):\([0-9]\{2\}\):\([0-9]\{2\}\)/\1-\2-\3/')
    create_date=$(echo "$create_date" | sed 's/^\([0-9]\{4\}\):\([0-9]\{2\}\):\([0-9]\{2\}\)/\1-\2-\3/')
    media_create=$(echo "$media_create" | sed 's/^\([0-9]\{4\}\):\([0-9]\{2\}\):\([0-9]\{2\}\)/\1-\2-\3/')
    track_create=$(echo "$track_create" | sed 's/^\([0-9]\{4\}\):\([0-9]\{2\}\):\([0-9]\{2\}\)/\1-\2-\3/')
    modify_date=$(echo "$modify_date" | sed 's/^\([0-9]\{4\}\):\([0-9]\{2\}\):\([0-9]\{2\}\)/\1-\2-\3/')
    
    # Select best date (fallback hierarchy) with validation
    local date=""
    local date_source=""
    local subsec_val=""
    local rejected_reason=""
    
    if validate_date "$datetime_original" "$min_year"; then
        date="$datetime_original"
        subsec_val="$subsec_orig"
        date_source="DateTimeOriginal"
    elif [ -n "$datetime_original" ]; then
        rejected_reason="DateTimeOriginal rejected: $datetime_original (failed validation, min_year=$min_year)"
    fi
    
    if [ -z "$date" ] && validate_date "$create_date" "$min_year"; then
        date="$create_date"
        subsec_val="$subsec_dig"
        [ -z "$subsec_val" ] && subsec_val="$subsec_time"
        date_source="CreateDate"
    elif [ -z "$date" ] && [ -n "$create_date" ]; then
        [ -z "$rejected_reason" ] && rejected_reason="CreateDate rejected: $create_date (failed validation, min_year=$min_year)"
    fi
    
    if [ -z "$date" ] && validate_date "$media_create" "$min_year"; then
        date="$media_create"
        date_source="MediaCreateDate"
    elif [ -z "$date" ] && [ -n "$media_create" ]; then
        [ -z "$rejected_reason" ] && rejected_reason="MediaCreateDate rejected: $media_create (failed validation, min_year=$min_year)"
    fi
    
    if [ -z "$date" ] && validate_date "$track_create" "$min_year"; then
        date="$track_create"
        date_source="TrackCreateDate"
    elif [ -z "$date" ] && [ -n "$track_create" ]; then
        [ -z "$rejected_reason" ] && rejected_reason="TrackCreateDate rejected: $track_create (failed validation, min_year=$min_year)"
    fi
    
    if [ -z "$date" ] && validate_date "$modify_date" "$min_year"; then
        date="$modify_date"
        subsec_val="$subsec_time"
        date_source="ModifyDate"
    elif [ -z "$date" ] && [ -n "$modify_date" ]; then
        [ -z "$rejected_reason" ] && rejected_reason="ModifyDate rejected: $modify_date (failed validation, min_year=$min_year)"
    fi
    
    # Try to parse date from filename (before FileModifyDate fallback)
    if [ -z "$date" ]; then
        local parsed_date=$(parse_date_from_filename "$full_path")
        if [ -n "$parsed_date" ] && validate_date "$parsed_date" "$min_year"; then
            date="$parsed_date"
            date_source="Filename"
            
            # Write parsed date to EXIF for future reliability
            local exif_update_log="$log_subdir/log_exif_updates.log"
            write_exif_date "$full_path" "$date" "filename" "$exif_update_log"
        fi
    fi
    
    # Try XMP sidecar file (Adobe/Lightroom/Darktable metadata)
    # XMP file has same name as photo but .xmp extension
    if [ -z "$date" ]; then
        local xmp_file="${full_path%.*}.xmp"
        [ ! -f "$xmp_file" ] && xmp_file="${full_path%.*}.XMP"
        if [ -f "$xmp_file" ]; then
            local xmp_date
            xmp_date=$(grep -o 'xmp:CreateDate="[^"]*"' "$xmp_file" 2>/dev/null | head -1 | cut -d'"' -f2)
            [ -z "$xmp_date" ] && xmp_date=$(grep -o 'xmp:MetadataDate="[^"]*"' "$xmp_file" 2>/dev/null | head -1 | cut -d'"' -f2)
            [ -z "$xmp_date" ] && xmp_date=$(grep -o 'photoshop:DateCreated>[^<]*' "$xmp_file" 2>/dev/null | head -1 | cut -d'>' -f2)
            # XMP date format: 2023-10-15T14:30:22 → normalize to 2023-10-15 14:30:22
            xmp_date=$(echo "$xmp_date" | sed 's/T/ /' | cut -c1-19)
            if [ -n "$xmp_date" ] && validate_date "$xmp_date" "$min_year"; then
                date="$xmp_date"
                date_source="XMP"
            fi
        fi
    fi
    
    # Try directory-based date (last resort before FileModifyDate)
    # If path contains YYYY/MM/DD structure, extract it
    if [ -z "$date" ]; then
        local dir_date
        dir_date=$(echo "$full_path" | grep -o '[0-9]\{4\}/[0-9]\{2\}/[0-9]\{2\}' | tail -1)
        if [ -n "$dir_date" ]; then
            dir_date=$(echo "$dir_date" | tr '/' '-')
            dir_date="$dir_date 00:00:00"
            if validate_date "$dir_date" "$min_year"; then
                date="$dir_date"
                date_source="DirectoryPath"
            fi
        fi
    fi
    
    # Fallback to system date (only if enabled)
    # WARNING: FileModifyDate can be unreliable (changes with copy/move operations)
    if [ -z "$date" ] && [ "$use_fallback" = "yes" ]; then
        local file_date=$(stat -c "%y" "$full_path" 2>/dev/null | cut -d'.' -f1)
        if [ -n "$file_date" ]; then
            # Validate FileModifyDate too (warn if suspiciously recent)
            if validate_date "$file_date" "$min_year"; then
                date="$file_date"
                date_source="FileModifyDate"
                
                # Warn if FileModifyDate is very recent (within last 30 days)
                local current_epoch=$(date +%s)
                local file_epoch=$(date -d "$file_date" +%s 2>/dev/null)
                local days_diff=$(( (current_epoch - file_epoch) / 86400 ))
                
                if [ "$days_diff" -lt 30 ]; then
                    [ -n "$rejected_log" ] && echo "WARNING: $full_path : Using recent FileModifyDate=$file_date (${days_diff}d old) - may be incorrect if file was recently copied/modified" >> "$rejected_log"
                fi
            elif [ -n "$rejected_log" ]; then
                rejected_reason="FileModifyDate rejected: $file_date (failed validation, min_year=$min_year)"
            fi
        fi
    fi
    
    # Save to log ONLY if no date even after fallback
    if [ -z "$date" ] && [ -n "$rejected_log" ]; then
        if [ -n "$rejected_reason" ]; then
            echo "$full_path : $rejected_reason (no fallback)" >> "$rejected_log"
        else
            echo "$full_path : No data at all (EXIF and system)" >> "$rejected_log"
        fi
    fi
    
    # Add milliseconds if present
    if [ -n "$subsec_val" ]; then
        date="${date}.${subsec_val}"
    fi
    
    # Generate new path
    if [ -n "$date" ]; then
        local new_path=$(generate_new_path "$full_path" "$date" "$output_dir")
        echo "$full_path|$date|OK|$new_path|$date_source" >> "$output_file"
    else
        echo "$full_path||NONE||" >> "$output_file"
    fi
}

# Process files (copy or move)
process_files() {
    local exif_data="$1"
    local task="$2"
    local log_subdir="${3:-.}"
    local total=$(wc -l < "$exif_data")
    local current=0
    local copied=0
    local moved=0
    local skipped=0
    local removed=0
    local failed=0
    
    echo ""
    if [ "$task" = "copy" ]; then
        echo "Copying files..."
    elif [ "$task" = "move" ]; then
        echo "Moving files..."
    else
        return 0
    fi
    
    # Debug log files
    local skipped_log="$log_subdir/log_skipped_files.log"
    local processed_log="$log_subdir/log_processed_files.log"
    local failed_log="$log_subdir/log_failed_files.log"
    local removed_log="$log_subdir/log_removed_duplicates.log"
    
    # Remove old logs if they exist
    rm -f "$skipped_log" "$processed_log" "$failed_log" "$removed_log"
    
    # Temporary file with operation statuses
    local status_file=$(mktemp)
    local last_percent=-1
    
    while IFS='|' read -r source_file date status new_path date_source; do
        current=$((current + 1))
        local percent=$((current * 100 / total))
        # Show progress only when percentage changes (reduces output from ~10000 to ~100 lines)
        if [ "$percent" -ne "$last_percent" ]; then
            printf "\rProcessing: %d/%d (%d%%)" "$current" "$total" "$percent"
            last_percent="$percent"
        fi
        
        # Skip files without date
        if [ "$status" != "OK" ]; then
            echo "$source_file|FAILED|No EXIF date" >> "$status_file"
            echo "FAILED: $source_file (No EXIF date)" >> "$failed_log"
            failed=$((failed + 1))
            continue
        fi
        
        # Create target directory
        local target_dir=$(dirname "$new_path")
        if ! mkdir -p "$target_dir" 2>/dev/null; then
            echo "$source_file|FAILED|Cannot create directory: $target_dir" >> "$status_file"
            echo "FAILED: $source_file (Cannot create directory: $target_dir)" >> "$failed_log"
            failed=$((failed + 1))
            continue
        fi
        
        # Check collisions and generate unique name
        local final_path=$(generate_unique_path "$new_path" "$source_file")
        
        if [ "$final_path" = "SKIP" ]; then
            echo "$source_file|SKIPPED|File already exists (identical MD5)" >> "$status_file"
            echo "SKIPPED: $source_file -> $new_path (identical MD5)" >> "$skipped_log"
            skipped=$((skipped + 1))
            
            # In move mode remove source (duplicate already exists in target location)
            if [ "$task" = "move" ]; then
                if rm "$source_file" 2>/dev/null; then
                    echo "REMOVED: $source_file (MD5 duplicate already exists: $new_path)" >> "$removed_log"
                    removed=$((removed + 1))
                else
                    echo "FAILED to remove: $source_file" >> "$removed_log"
                fi
            fi
            continue
        fi
        
        # Execute operation
        if [ "$task" = "copy" ]; then
            if cp "$source_file" "$final_path" 2>/dev/null; then
                echo "$source_file|COPIED|$final_path" >> "$status_file"
                echo "COPIED: [$date_source] $date : $source_file -> $final_path" >> "$processed_log"
                copied=$((copied + 1))
            else
                echo "$source_file|FAILED|Copy error" >> "$status_file"
                echo "FAILED: $source_file (Copy error)" >> "$failed_log"
                failed=$((failed + 1))
            fi
        elif [ "$task" = "move" ]; then
            if mv "$source_file" "$final_path" 2>/dev/null; then
                echo "$source_file|MOVED|$final_path" >> "$status_file"
                echo "MOVED: [$date_source] $date : $source_file -> $final_path" >> "$processed_log"
                moved=$((moved + 1))
            else
                echo "$source_file|FAILED|Move error" >> "$status_file"
                echo "FAILED: $source_file (Move error)" >> "$failed_log"
                failed=$((failed + 1))
            fi
        fi
    done < "$exif_data"
    
    echo ""
    echo ""
    echo "======================================"
    echo "OPERATION SUMMARY"
    echo "======================================"
    printf "Files with valid date: %5d (ready for operation)\n" "$total"
    echo ""
    if [ $copied -gt 0 ]; then
        printf "  Copied:           %5d files (%.1f%%)\n" "$copied" "$(awk "BEGIN {printf \"%.1f\", $copied * 100 / $total}")"
    fi
    if [ $moved -gt 0 ]; then
        printf "  Moved:         %5d files (%.1f%%)\n" "$moved" "$(awk "BEGIN {printf \"%.1f\", $moved * 100 / $total}")"
    fi
    if [ $skipped -gt 0 ]; then
        printf "  Skipped:            %5d files (%.1f%%) - identical MD5\n" "$skipped" "$(awk "BEGIN {printf \"%.1f\", $skipped * 100 / $total}")"
    fi
    if [ $removed -gt 0 ]; then
        printf "  Removed duplicates:   %5d files (%.1f%%) - sources deleted\n" "$removed" "$(awk "BEGIN {printf \"%.1f\", $removed * 100 / $total}")"
    fi
    if [ $failed -gt 0 ]; then
        printf "  Errors:                %5d files (%.1f%%)\n" "$failed" "$(awk "BEGIN {printf \"%.1f\", $failed * 100 / $total}")"
    fi
    echo "====================================="
    
    # Information about log files - only show if any logs were created
    local has_logs=0
    [ -f "$skipped_log" ] && has_logs=1
    [ -f "$removed_log" ] && has_logs=1
    [ -f "$processed_log" ] && has_logs=1
    [ -f "$failed_log" ] && has_logs=1
    
    if [ $has_logs -eq 1 ]; then
        echo ""
        echo "Log files:"
        [ -f "$skipped_log" ] && echo "  Skipped files:      $skipped_log"
        [ -f "$removed_log" ] && echo "  Removed duplicates: $removed_log"
        [ -f "$processed_log" ] && echo "  Processed files:    $processed_log"
        [ -f "$failed_log" ] && echo "  Errors:             $failed_log"
        [ -f "$log_subdir/log_ignored_files.log" ] && echo "  Ignored (pattern):  $log_subdir/log_ignored_files.log"
    fi
    
    # Show examples
    if [ $skipped -gt 0 ]; then
        echo ""
        echo "Examples of skipped files (first 5):"
        grep -F "|SKIPPED|" "$status_file" | head -5 | while IFS='|' read -r file status reason; do
            printf "  %s\n" "$file"
        done
    fi
    
    if [ $failed -gt 0 ]; then
        echo ""
        echo "Error examples (first 5):"
        grep -F "|FAILED|" "$status_file" | head -5 | while IFS='|' read -r file status reason; do
            local basename=$(basename "$file")
            printf "  %-30s : %s\n" "$basename" "$reason"
        done
    fi
    
    rm -f "$status_file"
}

# Display statistics of found files
display_statistics() {
    local file_list="$1"
    local total_count="$2"
    local exif_data="$3"
    local total_found="${4:-$total_count}"
    
    echo ""
    echo "======================================"
    echo "STATISTICS"
    echo "======================================"
    if [ "$total_found" != "$total_count" ]; then
        local not_analyzed=$((total_found - total_count))
        echo "Total found:       $total_found files"
        echo "Analyzed:          $total_count files"
        echo "Not analyzed:      $not_analyzed files ($(awk "BEGIN {printf \"%.1f\", $not_analyzed * 100 / $total_found}")%)"
    else
        echo "Total files:       $total_count"
    fi
    echo ""
    
    if [ $total_count -eq 0 ]; then
        echo "No files found to process"
        return
    fi
    
    # Ignored files summary (log written by analyze_exif_dates into LOG_SUBDIR)
    local ignored_count_stat=0
    if [ -f "$LOG_SUBDIR/log_ignored_files.log" ]; then
        ignored_count_stat=$(wc -l < "$LOG_SUBDIR/log_ignored_files.log")
    fi
    if [ "$ignored_count_stat" -gt 0 ]; then
        printf "Ignored (pattern):     %5d files (excluded before EXIF analysis)\n" "$ignored_count_stat"
        local analyzed_count=$(( total_count - ignored_count_stat ))
        [ "$analyzed_count" -lt 0 ] && analyzed_count=0
        printf "Analyzed:              %5d files\n" "$analyzed_count"
        echo ""
    fi
    
    # Statistics by extensions
    echo "Breakdown by extensions:"
    awk -F. '{print tolower($NF)}' "$file_list" | sort | uniq -c | sort -rn | while read count ext; do
        printf "  %-10s : %5d files\n" ".$ext" "$count"
    done
    
    # EXIF statistics
    echo ""
    echo "Date information:"
    local with_date=$(grep -cF "|OK|" "$exif_data")
    local without_date=$(grep -cF "|NONE|" "$exif_data")
    printf "  Files with date (ready to process): %5d (%.1f%%)\n" "$with_date" "$(awk "BEGIN {printf \"%.1f\", $with_date * 100 / $total_count}")"
    if [ $without_date -gt 0 ]; then
        printf "  Files WITHOUT date (skipped):             %5d (%.1f%%)\n" "$without_date" "$(awk "BEGIN {printf \"%.1f\", $without_date * 100 / $total_count}")"
    fi
    
    # Statistics by date source
    if [ $with_date -gt 0 ]; then
        echo ""
        echo "Breakdown by date source:"
        grep -F "|OK|" "$exif_data" | cut -d'|' -f5 | sort | uniq -c | sort -rn | while read count source; do
            if [ -n "$source" ]; then
                printf "  %-25s : %5d files (%.1f%%)\n" "$source" "$count" "$(awk "BEGIN {printf \"%.1f\", $count * 100 / $with_date}")"
            fi
        done
    fi
    
    # Example files with dates
    echo ""
    echo "Example files with EXIF date (first 10):"
    grep -F "|OK|" "$exif_data" | head -10 | while IFS='|' read -r file date status new_path source; do
        local basename=$(basename "$file")
        printf "  %-30s : %s [%s] -> %s\n" "$basename" "$date" "$source" "$new_path"
    done
    
    # Example files without dates
    if [ $without_date -gt 0 ]; then
        echo ""
        echo "Example files WITHOUT EXIF date (first 10):"
        grep -F "|NONE|" "$exif_data" | head -10 | while IFS='|' read -r file date status new_path source; do
            local basename=$(basename "$file")
            printf "  %-20s : [NO DATE] : %s\n" "$basename" "$file"
        done
    fi
    
    echo ""
    echo "======================================"
}

# ====================================
# MAIN
# ====================================

main() {
    # ====================================
    # LOG DIRECTORY WITH TIMESTAMP
    # ====================================
    local TIMESTAMP_START=$(date "+%Y_%m_%d_%H_%M_%S")
    local LOG_SUBDIR="$LOG_DIR/logs/$TIMESTAMP_START"
    mkdir -p "$LOG_SUBDIR" || {
        echo "Error: Cannot create log subdirectory: $LOG_SUBDIR"
        exit 1
    }
    
    # Record start time
    local start_time=$(date +%s)
    
    # Parse arguments
    local limit=""
    local task=""
    local no_fallback=""
    local min_year="1990"
    local src_dir=""
    local output_dir=""
    local ignore_file_arg=""
    
    # Check if help requested
    if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        show_help
        exit 0
    fi
    
    # Parse options
    while [ $# -gt 0 ]; do
        case "$1" in
            --limit=*)
                limit="${1#*=}"
                shift
                ;;
            --task=*)
                task="${1#*=}"
                shift
                ;;
            --min-year=*)
                min_year="${1#*=}"
                shift
                ;;
            --no-fallback-date)
                no_fallback="no-fallback"
                shift
                ;;
            --keepSourceTag)
                KEEP_SOURCE_TAG="yes"
                shift
                ;;
            --ignoreFile=*)
                ignore_file_arg="${1#*=}"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                if [ -z "$src_dir" ]; then
                    src_dir="$1"
                elif [ -z "$output_dir" ]; then
                    output_dir="$1"
                else
                    echo "Error: Too many arguments"
                    echo ""
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done
    
    # Validate arguments
    if [ -z "$src_dir" ] || [ -z "$output_dir" ]; then
        echo "Error: Two arguments required: source_directory and target_directory"
        echo ""
        show_help
        exit 1
    fi
    
    # Validate limit
    if [ -n "$limit" ] && ! [[ "$limit" =~ ^[0-9]+$ ]]; then
        echo "Error: Limit must be an integer"
        exit 1
    fi
    
    # Validate task
    if [ -n "$task" ] && [ "$task" != "copy" ] && [ "$task" != "move" ]; then
        echo "Error: --task must be 'copy' or 'move'"
        exit 1
    fi
    
    # Validate min_year
    if ! [[ "$min_year" =~ ^[0-9]{4}$ ]]; then
        echo "Error: --min-year must be a 4-digit year (e.g. 2000)"
        exit 1
    fi
    
    # Parse --ignoreFile patterns (comma-separated) into global array
    # Leading/trailing whitespace is stripped from each pattern so that
    # "--ignoreFile=Screenshot_, Paint_" works the same as "Screenshot_,Paint_"
    if [ -n "$ignore_file_arg" ]; then
        IFS=',' read -ra _raw_patterns <<< "$ignore_file_arg"
        for _p in "${_raw_patterns[@]}"; do
            _p="${_p#"${_p%%[! ]*}"}"  # trim leading spaces
            _p="${_p%"${_p##*[! ]}"}"  # trim trailing spaces
            [ -n "$_p" ] && IGNORE_FILE_PATTERNS+=("$_p")
        done
        unset _raw_patterns _p
    fi
    
    # Determine lock path based on the destination directory to avoid
    # unrelated runs blocking each other when they use different output targets.
    set_lock_file "$output_dir"

    # Acquire lock file and prevent concurrent writes to the same output
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(head -n 1 "$LOCK_FILE" 2>/dev/null)
        local lock_time
        lock_time=$(tail -n 1 "$LOCK_FILE" 2>/dev/null)

        if [ -n "$lock_pid" ] && kill -0 "$lock_pid" >/dev/null 2>&1; then
            echo "Error: Another instance is already running for the same output directory"
            echo "  Lock file: $LOCK_FILE"
            echo "  Process ID: $lock_pid"
            echo "  Started at: $lock_time"
            echo ""
            echo "If you are sure no other instance is running, remove the lock file:"
            echo "  rm $LOCK_FILE"
            exit 1
        fi

        echo "Warning: Removing stale lock file: $LOCK_FILE" >&2
        rm -f "$LOCK_FILE" 2>/dev/null || {
            echo "Error: Cannot remove stale lock file: $LOCK_FILE"
            exit 1
        }
    fi

    {
        echo "$$"
        date "+%Y-%m-%d %H:%M:%S"
    } > "$LOCK_FILE" || {
        echo "Error: Cannot create lock file at $LOCK_FILE"
        exit 1
    }

    trap "rm -f '$LOCK_FILE'" EXIT
    trap "rm -f '$LOCK_FILE'; exit 130" INT TERM

    # Check requirements
    check_exiftool
    check_source_dir "$src_dir"
    
    # Process files
    scan_files "$src_dir" "$output_dir" "$limit" "$task" "$no_fallback" "$min_year"
    
    # Calculate and display execution time
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    local minutes=$((elapsed / 60))
    local seconds=$((elapsed % 60))
    
    echo ""
    if [ -n "$task" ]; then
        echo "Processing completed"
    else
        echo "Analysis completed (dry-run)"
    fi
    
    # Show EXIF update summary if log exists
    if [ -f "$LOG_SUBDIR/log_exif_updates.log" ]; then
        local exif_success=$(grep -c "^\[SUCCESS\]" "$LOG_SUBDIR/log_exif_updates.log" 2>/dev/null)
        local exif_failed=$(grep -c "^\[FAILED\]" "$LOG_SUBDIR/log_exif_updates.log" 2>/dev/null)
        # Ensure numeric values (remove newlines, default to 0)
        exif_success=$(echo "$exif_success" | tr -d '\n' | grep -o '[0-9]*')
        exif_failed=$(echo "$exif_failed" | tr -d '\n' | grep -o '[0-9]*')
        exif_success=${exif_success:-0}
        exif_failed=${exif_failed:-0}
        if [ "$exif_success" -gt 0 ] 2>/dev/null || [ "$exif_failed" -gt 0 ] 2>/dev/null; then
            echo ""
            echo "EXIF Updates (dates parsed from filenames and written to EXIF tags):"
            [ "$exif_success" -gt 0 ] 2>/dev/null && echo "  Successfully updated: $exif_success files"
            [ "$exif_failed" -gt 0 ] 2>/dev/null && echo "  Failed to update:     $exif_failed files"
            echo "  See log_exif_updates.log for details"
        fi
    fi
    
    if [ $elapsed -ge 60 ]; then
        printf "\nTotal execution time: %d min %d sec\n" "$minutes" "$seconds"
    else
        printf "\nTotal execution time: %d sec\n" "$elapsed"
    fi
    
    # ====================================
    # STATUS LOG - Record execution summary
    # ====================================
    {
        echo "Execution Status Report"
        echo "======================================"
        echo "Started at:  $(date -d @$start_time "+%Y-%m-%d %H:%M:%S")"
        echo "Ended at:    $(date "+%Y-%m-%d %H:%M:%S")"
        echo "Duration:    ${minutes}m ${seconds}s"
        echo "Status:      SUCCESS"
        echo ""
        echo "Log directory: $LOG_SUBDIR"
        echo "Mode:          $([ -n "$task" ] && echo "$task" || echo "dry-run (analysis only)")"
    } > "$LOG_SUBDIR/status.log"
    
    echo ""
    echo "All logs saved to: $LOG_SUBDIR"
}

# Run main function
main "$@"
