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

# Lock file (prevents multiple simultaneous runs)
LOCK_FILE="/tmp/manage_images.lock"

# ====================================
# CONFIGURATION
# ====================================

# Path to exiftool (relative to script directory)
EXIFTOOL="$SCRIPT_DIR/Image-ExifTool/exiftool"

# Image file extensions
IMAGE_EXTENSIONS="jpg jpeg png gif bmp tiff tif raw cr2 nef arw dng heic heif webp"

# Video file extensions
VIDEO_EXTENSIONS="mp4 mov avi mkv wmv flv webm m4v mpg mpeg 3gp mts m2ts"

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
)

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
    
    # Full path, only EXIF > 2010, logs to /tmp
    LOG_DIR=/tmp $0 --task=copy --min-year=2010 /home/user/photos /home/user/output

SUPPORTED EXTENSIONS:
    Images: $IMAGE_EXTENSIONS
    Video:  $VIDEO_EXTENSIONS

SKIPPED DIRECTORIES:
    $(printf '%s, ' "${EXCLUDE_DIRS[@]}" | sed 's/, $//')

EOF
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

# Check if exiftool exists
check_exiftool() {
    if [ ! -f "$EXIFTOOL" ]; then
        echo "Error: exiftool not found at $EXIFTOOL"
        exit 1
    fi
    
    # Show exiftool version
    local version=$("$EXIFTOOL" -ver)
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

# Extract photo creation date from EXIF (with milliseconds if available)
# 
# FALLBACK HIERARCHY (from most to least reliable):
# 1. DateTimeOriginal (EXIF:DateTimeOriginal) + SubSecTimeOriginal
#    - Original time photo was taken by camera
#    - Most reliable source
# 
# 2. CreateDate (EXIF:CreateDate) + SubSecTimeDigitized or SubSecTime
#    - Digitization time or file creation time
#    - Second most reliable source
#
# 3. MediaCreateDate (QuickTime:MediaCreateDate)
#    - For video files (MP4, MOV, etc.)
#
# 4. TrackCreateDate (QuickTime:TrackCreateDate)
#    - Alternative field for video
#
# 5. ModifyDate (EXIF:ModifyDate) + SubSecTime
#    - Date of last metadata modification
#    - Less reliable (changes when edited)
#
# 6. Filename parsing (if filename contains date pattern)
#    - Patterns: IMG_YYYYMMDD_HHMMSS, YYYYMMDD_HHMMSS, Screenshot_YYYYMMDD-HHMMSS
#    - Extracted date is validated (min_year check)
#    - Automatically written to EXIF (DateTimeOriginal + CreateDate)
#    - See log_exif_updates.log for write operations
#
# 7. FileModifyDate (system file modification date)
#    - Last resort, least reliable (changes on copy/move)
#    - Validated with warning if very recent (< 30 days)
#
# MILLISECONDS: Photos may contain milliseconds in fields:
# - SubSecTimeOriginal, SubSecTimeDigitized, SubSecTime
# - Format: 0-999 (e.g. "123" means 0.123 seconds)
#
get_exif_date() {
    local file="$1"
    local date=""
    local subsec=""
    local source=""
    
    # 1. Try DateTimeOriginal (most important date - when photo was taken)
    date=$("$EXIFTOOL" -DateTimeOriginal -d "%Y-%m-%d %H:%M:%S" -s3 "$file" 2>/dev/null)
    if [ -n "$date" ]; then
        subsec=$("$EXIFTOOL" -SubSecTimeOriginal -s3 "$file" 2>/dev/null)
        source="DateTimeOriginal"
    fi
    
    # 2. If no DateTimeOriginal, try CreateDate
    if [ -z "$date" ]; then
        date=$("$EXIFTOOL" -CreateDate -d "%Y-%m-%d %H:%M:%S" -s3 "$file" 2>/dev/null)
        if [ -n "$date" ]; then
            subsec=$("$EXIFTOOL" -SubSecTimeDigitized -s3 "$file" 2>/dev/null)
            [ -z "$subsec" ] && subsec=$("$EXIFTOOL" -SubSecTime -s3 "$file" 2>/dev/null)
            source="CreateDate"
        fi
    fi
    
    # 3. For video: MediaCreateDate
    if [ -z "$date" ] && is_video_file "$file"; then
        date=$("$EXIFTOOL" -MediaCreateDate -d "%Y-%m-%d %H:%M:%S" -s3 "$file" 2>/dev/null)
        [ -n "$date" ] && source="MediaCreateDate"
    fi
    
    # 4. For video: TrackCreateDate
    if [ -z "$date" ] && is_video_file "$file"; then
        date=$("$EXIFTOOL" -TrackCreateDate -d "%Y-%m-%d %H:%M:%S" -s3 "$file" 2>/dev/null)
        [ -n "$date" ] && source="TrackCreateDate"
    fi
    
    # 5. Last resort: ModifyDate (least reliable)
    if [ -z "$date" ]; then
        date=$("$EXIFTOOL" -ModifyDate -d "%Y-%m-%d %H:%M:%S" -s3 "$file" 2>/dev/null)
        if [ -n "$date" ]; then
            subsec=$("$EXIFTOOL" -SubSecTime -s3 "$file" 2>/dev/null)
            source="ModifyDate"
        fi
    fi
    
    # 6. Last resort: system file date
    if [ -z "$date" ]; then
        date=$(stat -c "%y" "$file" 2>/dev/null | cut -d'.' -f1)
        [ -n "$date" ] && source="FileModifyDate"
    fi
    
    # Add milliseconds if available and return date with source
    if [ -n "$date" ] && [ -n "$subsec" ]; then
        echo "${date}.${subsec}|${source}"
    elif [ -n "$date" ]; then
        echo "${date}|${source}"
    fi
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
    
    # Generate new name: PREFIX_YYYYMMDD_HHMMSS[_sss].ext
    # Date format: no separators (20061225_113031)
    local new_filename
    if [ -n "$subsec" ]; then
        # Normalize milliseconds to 3 digits (padding with zeros on right)
        # Examples: "5" → "500", "12" → "120", "123" → "123"
        local subsec_padded=$(printf "%-3s" "$subsec" | tr ' ' '0')
        new_filename="${prefix}_${year}${month}${day}_${time}_${subsec_padded}.${ext}"
    else
        new_filename="${prefix}_${year}${month}${day}_${time}.${ext}"
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
    
    # Process each file individually for accurate EXIF reading
    # This ensures proper date priority and avoids batch parsing issues
    local current=0
    local last_percent=-1
    
    while IFS= read -r file; do
        [ -z "$file" ] && continue
        
        current=$((current + 1))
        local percent=$((current * 100 / total))
        # Show progress only when percentage changes (reduces output from ~10000 to ~100 lines)
        if [ "$percent" -ne "$last_percent" ]; then
            printf "\rProcessing: %d/%d (%d%%)" "$current" "$total" "$percent"
            last_percent="$percent"
        fi
        
        # Extract EXIF data for single file
        local datetime_original=$("$EXIFTOOL" -DateTimeOriginal -d "%Y:%m:%d %H:%M:%S" -s3 "$file" 2>/dev/null)
        local subsec_orig=$("$EXIFTOOL" -SubSecTimeOriginal -s3 "$file" 2>/dev/null)
        local create_date=$("$EXIFTOOL" -CreateDate -d "%Y:%m:%d %H:%M:%S" -s3 "$file" 2>/dev/null)
        local subsec_dig=$("$EXIFTOOL" -SubSecTimeDigitized -s3 "$file" 2>/dev/null)
        local subsec_time=$("$EXIFTOOL" -SubSecTime -s3 "$file" 2>/dev/null)
        local media_create=$("$EXIFTOOL" -MediaCreateDate -d "%Y:%m:%d %H:%M:%S" -s3 "$file" 2>/dev/null)
        local track_create=$("$EXIFTOOL" -TrackCreateDate -d "%Y:%m:%d %H:%M:%S" -s3 "$file" 2>/dev/null)
        local modify_date=$("$EXIFTOOL" -ModifyDate -d "%Y:%m:%d %H:%M:%S" -s3 "$file" 2>/dev/null)
        
        # Process this file with extracted EXIF data
        process_exif_data "$file" "$datetime_original" "$subsec_orig" \
            "$create_date" "$subsec_dig" "$subsec_time" \
            "$media_create" "$track_create" "$modify_date" \
            "$output_dir" "$output_file" "$use_fallback" "$min_year" "$rejected_log" "$log_subdir"
            
    done < "$file_list"
    
    # Show information about rejected dates
    if [ -f "$rejected_log" ]; then
        local rejected_count=$(wc -l < "$rejected_log")
        if [ "$rejected_count" -gt 0 ]; then
            echo ""
            echo "Warning: $rejected_count files without any date (details in $rejected_log)"
        fi
    fi
    
    rm -f "$temp_exif_output"
    echo ""
}

# Parse date from filename (e.g., IMG_20130410_094342.jpg → 2013-04-10 09:43:42)
parse_date_from_filename() {
    local filename="$1"
    local basename=$(basename "$filename")
    
    # Pattern 1: IMG_YYYYMMDD_HHMMSS or similar
    if [[ "$basename" =~ ([0-9]{8})_([0-9]{6}) ]]; then
        local date_part="${BASH_REMATCH[1]}"
        local time_part="${BASH_REMATCH[2]}"
        
        local year="${date_part:0:4}"
        local month="${date_part:4:2}"
        local day="${date_part:6:2}"
        local hour="${time_part:0:2}"
        local min="${time_part:2:2}"
        local sec="${time_part:4:2}"
        
        echo "${year}-${month}-${day} ${hour}:${min}:${sec}"
        return 0
    fi
    
    # Pattern 2: YYYYMMDD_HHMMSS at the beginning
    if [[ "$basename" =~ ^([0-9]{8})_([0-9]{6}) ]]; then
        local date_part="${BASH_REMATCH[1]}"
        local time_part="${BASH_REMATCH[2]}"
        
        local year="${date_part:0:4}"
        local month="${date_part:4:2}"
        local day="${date_part:6:2}"
        local hour="${time_part:0:2}"
        local min="${time_part:2:2}"
        local sec="${time_part:4:2}"
        
        echo "${year}-${month}-${day} ${hour}:${min}:${sec}"
        return 0
    fi
    
    # Pattern 3: Screenshot_YYYYMMDD-HHMMSS
    if [[ "$basename" =~ ([0-9]{8})-([0-9]{6}) ]]; then
        local date_part="${BASH_REMATCH[1]}"
        local time_part="${BASH_REMATCH[2]}"
        
        local year="${date_part:0:4}"
        local month="${date_part:4:2}"
        local day="${date_part:6:2}"
        local hour="${time_part:0:2}"
        local min="${time_part:2:2}"
        local sec="${time_part:4:2}"
        
        echo "${year}-${month}-${day} ${hour}:${min}:${sec}"
        return 0
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
    if ./Image-ExifTool/exiftool -DateTimeOriginal="$exif_date" -CreateDate="$exif_date" -overwrite_original "$file" >/dev/null 2>&1; then
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
    # LOCK FILE - Prevent multiple runs
    # ====================================
    if [ -f "$LOCK_FILE" ]; then
        local lock_pid=$(head -n 1 "$LOCK_FILE" 2>/dev/null)
        local lock_time=$(tail -n 1 "$LOCK_FILE" 2>/dev/null)
        echo "Error: Script is already running"
        echo "  Lock file: $LOCK_FILE"
        echo "  Process ID: $lock_pid"
        echo "  Started at: $lock_time"
        echo ""
        echo "If you are sure no other instance is running, remove the lock file:"
        echo "  rm $LOCK_FILE"
        exit 1
    fi
    
    # Create lock file with PID and timestamp
    {
        echo "$$"
        date "+%Y-%m-%d %H:%M:%S"
    } > "$LOCK_FILE" || {
        echo "Error: Cannot create lock file at $LOCK_FILE"
        exit 1
    }
    
    # Cleanup lock file on exit, error, or signal (INT=Ctrl+C, TERM=termination)
    trap "rm -f '$LOCK_FILE'" EXIT
    trap "rm -f '$LOCK_FILE'; exit 130" INT TERM
    
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

