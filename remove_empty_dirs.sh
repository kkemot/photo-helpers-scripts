#!/bin/bash

# Script for removing empty directories (without multimedia files)
# Uses the same criteria as manage_images.sh

# ====================================
# CONFIGURATION
# ====================================

# Image file extensions (as in scan_images.sh)
IMAGE_EXTENSIONS="jpg jpeg png gif bmp tiff tif raw cr2 nef arw dng heic heif webp"

# Video file extensions (as in scan_images.sh)
VIDEO_EXTENSIONS="mp4 mov avi mkv wmv flv webm m4v mpg mpeg 3gp mts m2ts"

# Directories to skip (as in scan_images.sh)
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
Usage: $0 [OPTIONS] <source_directory>

Script finds and removes empty directories (without multimedia files).

ARGUMENTS:
    source_directory    Directory to search

OPTIONS:
    -h, --help          Display this help
    --dry-run           Only shows what will be deleted (default)
    --delete            Actually deletes empty directories (including hidden system files)
    --min-depth=N       Minimum directory depth (default: 1, does not delete root)

EXAMPLES:
    # Preview - what will be deleted
    $0 ./src
    
    # Actual deletion
    $0 --delete ./src
    
    # Delete only directories at depth 2 or more
    $0 --delete --min-depth=2 ./src

MULTIMEDIA EXTENSIONS:
    Images: $IMAGE_EXTENSIONS
    Video:  $VIDEO_EXTENSIONS

IGNORED DIRECTORIES:
    $(printf '%s, ' "${EXCLUDE_DIRS[@]}" | sed 's/, $//')

NOTE:
    - Directories containing ONLY system files (.ini, .db, etc.) will be considered empty
    - Nested directories are removed from deepest to shallowest
    - Temporary directories are ignored but NOT automatically deleted

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

# Build pattern for multimedia file extensions
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

# Check if directory contains multimedia files
has_media_files() {
    local dir="$1"
    local exclude_pattern=$(build_exclude_pattern)
    local all_extensions="$IMAGE_EXTENSIONS $VIDEO_EXTENSIONS"
    local extension_pattern=$(build_extension_pattern "$all_extensions")

    # Search for multimedia files (only in this directory, not recursively)
    local count=$(eval "find '$dir' -maxdepth 1 -type f \( $extension_pattern \) 2>/dev/null | wc -l")

    [ "$count" -gt 0 ] && return 0 || return 1
}

# Check if directory should be ignored
should_ignore_dir() {
    local dir="$1"
    local basename=$(basename "$dir")

    for exclude in "${EXCLUDE_DIRS[@]}"; do
        if [ "$basename" = "$exclude" ]; then
            return 0
        fi
    done
    return 1
}

# Find empty directories
find_empty_dirs() {
    local src_dir="$1"
    local min_depth="${2:-1}"
    local exclude_pattern=$(build_exclude_pattern)

    # Find all directories (from deepest), excluding ignored
    eval "find '$src_dir' $exclude_pattern -o -type d -print" | sort -r | while read -r dir; do
        # Skip main directory if min_depth > 0
        if [ "$min_depth" -gt 0 ] && [ "$dir" = "$src_dir" ]; then
            continue
        fi

        # Check depth
        local depth=$(echo "$dir" | sed "s|$src_dir||" | grep -o "/" | wc -l)
        if [ "$depth" -lt "$min_depth" ]; then
            continue
        fi

        # Skip ignored directories
        if should_ignore_dir "$dir"; then
            continue
        fi

        # Check if directory contains multimedia files (recursively)
        local exclude_pattern_inner=$(build_exclude_pattern)
        local all_extensions="$IMAGE_EXTENSIONS $VIDEO_EXTENSIONS"
        local extension_pattern=$(build_extension_pattern "$all_extensions")

        local media_count=$(eval "find '$dir' $exclude_pattern_inner -o -type f \( $extension_pattern \) -print 2>/dev/null | wc -l")

        if [ "$media_count" -eq 0 ]; then
            # Check if directory has any files (not directories)
            local file_count=$(find "$dir" -type f 2>/dev/null | wc -l)

            if [ "$file_count" -eq 0 ]; then
                echo "$dir|EMPTY|No files"
            else
                echo "$dir|NO_MEDIA|No multimedia files (only system files: $file_count)"
            fi
        fi
    done
}

# Remove empty directories
remove_empty_dirs() {
    local empty_list="$1"
    local dry_run="$2"
    local removed=0
    local failed=0
    local skipped=0
    local with_hidden=0

    echo ""
    if [ "$dry_run" = "yes" ]; then
        echo "=== PREVIEW MODE - directories will NOT be deleted ==="
    else
        echo "=== DELETING empty directories ==="
    fi
    echo ""

    while IFS='|' read -r dir status reason; do
        if [ "$dry_run" = "yes" ]; then
            echo "WILL BE DELETED: $dir"
            echo "  Reason: $reason"
            removed=$((removed + 1))
        else
            if rmdir "$dir" 2>/dev/null; then
                echo "DELETED: $dir"
                removed=$((removed + 1))
            else
                # Check if directory still exists
                if [ -d "$dir" ]; then
                    # Check what blocks deletion
                    local hidden_files=$(find "$dir" -maxdepth 1 -name ".*" -type f 2>/dev/null | wc -l)
                    local subdirs=$(find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
                    local regular_files=$(find "$dir" -maxdepth 1 -type f ! -name ".*" 2>/dev/null | wc -l)

                    # Check if there are any multimedia files (not system)
                    local media_files=$(find "$dir" -maxdepth 1 -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.gif" -o -iname "*.bmp" -o -iname "*.tiff" -o -iname "*.tif" -o -iname "*.raw" -o -iname "*.cr2" -o -iname "*.nef" -o -iname "*.arw" -o -iname "*.dng" -o -iname "*.heic" -o -iname "*.heif" -o -iname "*.webp" -o -iname "*.mp4" -o -iname "*.mov" -o -iname "*.avi" -o -iname "*.mkv" -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.webm" -o -iname "*.m4v" -o -iname "*.mpg" -o -iname "*.mpeg" -o -iname "*.3gp" -o -iname "*.mts" -o -iname "*.m2ts" \) 2>/dev/null | wc -l)

                    # If only system files and system subdirectories (no multimedia files)
                    if [ "$media_files" -eq 0 ]; then
                        # Remove system directories (@eaDir, .thumbnails, etc.) recursively
                        find "$dir" -maxdepth 1 -type d \( -name "@eaDir" -o -name ".thumbnails" -o -name ".picasaoriginals" -o -name "#recycle" -o -name "@Recycle" -o -name ".synology" -o -name "@tmp" \) -exec rm -rf {} + 2>/dev/null

                        # Remove hidden system files (.picasa.ini, .ini, .db, .DS_Store)
                        find "$dir" -maxdepth 1 -name ".*" -type f \( -name "*.ini" -o -name "*.db" -o -name ".picasa*" -o -name ".DS_Store" \) -delete 2>/dev/null

                        # Remove Thumbs.db (non-hidden system file)
                        find "$dir" -maxdepth 1 -name "Thumbs.db" -type f -delete 2>/dev/null

                        # Remove thumbnail files (.thm, .ctg, .info etc.)
                        find "$dir" -maxdepth 1 -type f \( -iname "*.thm" -o -iname "*.ctg" -o -iname "*.info" \) -delete 2>/dev/null

                        # Try to remove directory again
                        if rmdir "$dir" 2>/dev/null; then
                            echo "DELETED: $dir"
                            if [ "$hidden_files" -gt 0 ] || [ "$subdirs" -gt 0 ]; then
                                echo "  (deleted system files and directories)"
                            fi
                            removed=$((removed + 1))
                            with_hidden=$((with_hidden + 1))
                        else
                            echo "ERROR: Cannot delete: $dir"
                            local remaining_files=$(find "$dir" -maxdepth 1 -type f 2>/dev/null | head -5)
                            if [ -n "$remaining_files" ]; then
                                echo "  Remaining files:"
                                echo "$remaining_files" | while read -r f; do
                                    echo "    - $(basename "$f")"
                                done
                            fi
                            failed=$((failed + 1))
                        fi
                    else
                        echo "ERROR: Cannot delete: $dir"
                        if [ "$hidden_files" -gt 0 ]; then
                            echo "  Hidden files ($hidden_files):"
                            find "$dir" -maxdepth 1 -name ".*" -type f 2>/dev/null | head -3 | while read -r f; do
                                echo "    - $(basename "$f")"
                            done
                            if [ "$hidden_files" -gt 3 ]; then
                                echo "    ... and $((hidden_files - 3)) more"
                            fi
                        fi
                        if [ "$subdirs" -gt 0 ]; then
                            echo "  Subdirectories ($subdirs):"
                            find "$dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -3 | while read -r d; do
                                echo "    - $(basename "$d")"
                            done
                            if [ "$subdirs" -gt 3 ]; then
                                echo "    ... and $((subdirs - 3)) more"
                            fi
                        fi
                        if [ "$regular_files" -gt 0 ]; then
                            echo "  Regular files ($regular_files):"
                            find "$dir" -maxdepth 1 -type f ! -name ".*" 2>/dev/null | head -3 | while read -r f; do
                                echo "    - $(basename "$f")"
                            done
                            if [ "$regular_files" -gt 3 ]; then
                                echo "    ... and $((regular_files - 3)) more"
                            fi
                        fi
                        failed=$((failed + 1))
                    fi
                else
                    # Directory no longer exists (was deleted by parent operation)
                    skipped=$((skipped + 1))
                fi
            fi
        fi
    done < "$empty_list"
    
    echo ""
    echo "======================================"
    echo "SUMMARY"
    echo "======================================"
    if [ "$dry_run" = "yes" ]; then
        printf "Directories to delete: %5d\n" "$removed"
        echo ""
        echo "To actually delete, run with --delete option"
    else
        printf "Deleted:               %5d directories\n" "$removed"
        if [ "$with_hidden" -gt 0 ]; then
            printf "  (including %d with hidden system files)\n" "$with_hidden"
        fi
        if [ $skipped -gt 0 ]; then
            printf "Skipped:              %5d directories (no longer exist)\n" "$skipped"
        fi
        if [ $failed -gt 0 ]; then
            printf "Errors:                  %5d directories\n" "$failed"

        fi
    fi
    echo "====================================="
}

# Main scanning function
scan_empty_dirs() {
    local src_dir="$1"
    local dry_run="$2"
    local min_depth="${3:-1}"

    echo "======================================"
    echo "Finding empty directories"
    echo "======================================"
    echo "Source directory:  $src_dir"
    echo "Minimum depth: $min_depth"
    if [ "$dry_run" = "yes" ]; then
        echo "Mode:              preview (dry-run)"
    else
        echo "Mode:              deletion (--delete)"
    fi
    echo ""

    # Check if directory exists
    if [ ! -d "$src_dir" ]; then
        echo "Error: Directory '$src_dir' does not exist"
        exit 1
    fi

    # Find empty directories
    echo "Searching directories..."
    local temp_list=$(mktemp)
    local temp_kept=$(mktemp)

    # Find directories with multimedia files (which will be KEPT)
    local exclude_pattern=$(build_exclude_pattern)
    local all_extensions="$IMAGE_EXTENSIONS $VIDEO_EXTENSIONS"
    local extension_pattern=$(build_extension_pattern "$all_extensions")

    eval "find '$src_dir' $exclude_pattern -o -type d -print" | sort | while read -r dir; do
        # Skip main directory if min_depth > 0
        if [ "$min_depth" -gt 0 ] && [ "$dir" = "$src_dir" ]; then
            continue
        fi

        # Check depth
        local depth=$(echo "$dir" | sed "s|$src_dir||" | grep -o "/" | wc -l)
        if [ "$depth" -lt "$min_depth" ]; then
            continue
        fi

        # Skip ignored directories
        if should_ignore_dir "$dir"; then
            continue
        fi

        # Check if directory contains multimedia files
        local media_count=$(eval "find '$dir' -maxdepth 1 -type f \( $extension_pattern \) 2>/dev/null | wc -l")

        if [ "$media_count" -gt 0 ]; then
            echo "$dir|$media_count" >> "$temp_kept"
        fi
    done

    # Find empty directories
    find_empty_dirs "$src_dir" "$min_depth" > "$temp_list"

    local empty_count=$(wc -l < "$temp_list")
    local kept_count=$(wc -l < "$temp_kept" 2>/dev/null || echo 0)

    if [ "$empty_count" -eq 0 ]; then
        echo ""
        echo "No empty directories found! 🎉"
        echo ""
        if [ "$kept_count" -gt 0 ]; then
            echo "Directories with multimedia files: $kept_count"
        fi
        rm -f "$temp_list" "$temp_kept"
        return 0
    fi

    echo "Found empty directories: $empty_count"
    if [ "$kept_count" -gt 0 ]; then
        echo "Directories with multimedia (kept): $kept_count"
    fi

    # Show statistics
    echo ""
    echo "Breakdown by type:"
    local empty_empty=$(grep -c "|EMPTY|" "$temp_list" 2>/dev/null | head -1)
    local empty_nomedia=$(grep -c "|NO_MEDIA|" "$temp_list" 2>/dev/null | head -1)
    empty_empty=${empty_empty:-0}
    empty_nomedia=${empty_nomedia:-0}

    if [ "$empty_empty" -gt 0 ]; then
        printf "  Completely empty:        %5d directories\n" "$empty_empty"
    fi
    if [ "$empty_nomedia" -gt 0 ]; then
        printf "  Only system files:   %5d directories\n" "$empty_nomedia"
    fi

    # Examples of empty directories (to be deleted)
    echo ""
    echo "Examples of directories TO DELETE (first 10):"
    head -10 "$temp_list" | while IFS='|' read -r dir status reason; do
        echo "  $dir"
        echo "    → $reason"
    done

    if [ "$empty_count" -gt 10 ]; then
        echo "  ... i $((empty_count - 10)) more"
    fi

    # Examples of directories with multimedia (which will NOT be deleted)
    if [ "$kept_count" -gt 0 ]; then
        echo ""
        echo "Examples of KEPT directories (with multimedia, first 20):"
        head -20 "$temp_kept" | while IFS='|' read -r dir count; do
            echo "  $dir"
            echo "    → Contains $count multimedia files"
        done

        if [ "$kept_count" -gt 20 ]; then
            echo "  ... i $((kept_count - 20)) more"
        fi
    fi

    # Remove directories
    remove_empty_dirs "$temp_list" "$dry_run"

    # Cleanup
    rm -f "$temp_list" "$temp_kept"
}

# ====================================
# MAIN
# ====================================

main() {
    local src_dir=""
    local dry_run="yes"
    local min_depth="1"

    # Check if help requested
    if [ $# -eq 0 ] || [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
        show_help
        exit 0
    fi

    # Parse options
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run)
                dry_run="yes"
                shift
                ;;
            --delete)
                dry_run="no"
                shift
                ;;
            --min-depth=*)
                min_depth="${1#*=}"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                if [ -z "$src_dir" ]; then
                    src_dir="$1"
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
    if [ -z "$src_dir" ]; then
        echo "Error: Source directory is required"
        echo ""
        show_help
        exit 1
    fi

    # Validate min_depth
    if ! [[ "$min_depth" =~ ^[0-9]+$ ]]; then
        echo "Error: --min-depth must be an integer"
        exit 1
    fi

    # Scanning
    scan_empty_dirs "$src_dir" "$dry_run" "$min_depth"

    echo ""
    echo "Completed"
}

# Run main function
main "$@"
