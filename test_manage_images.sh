#!/bin/bash
# =============================================================================
# test_manage_images.sh — integration smoke test for manage_images.sh
#
# Generates ~500 synthetic photo/video files covering every supported date
# source (EXIF, all 8 filename patterns, XMP sidecar, directory path,
# FileModifyDate fallback) plus targeted edge cases (invalid dates, MD5
# duplicates, ignored Synology thumbs, the pattern-8 trap fixed in the latest
# refactor). Runs `manage_images.sh --task=move` against this corpus, asserts
# expected outcomes against the resulting `test/output/` tree and log files,
# then prints a PASS/FAIL summary with total elapsed time and cleans up.
#
# Usage:
#   ./test_manage_images.sh           # run, clean test/ on success
#   ./test_manage_images.sh --keep    # always preserve test/ for inspection
#
# Exit codes:
#   0 — all assertions passed
#   1 — one or more assertions failed
#   2 — setup error (exiftool missing, corpus could not be created, etc.)
#
# Requirements:
#   - manage_images.sh in the same directory
#   - exiftool: bundled at ./Image-ExifTool/exiftool OR available on $PATH
#   - standard tools: bash 4+, find, md5sum, base64, touch, date
# =============================================================================

set -u

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_ROOT="$SCRIPT_DIR/test"
INPUT_DIR="$TEST_ROOT/input"
OUTPUT_DIR="$TEST_ROOT/output"
TEST_LOG_DIR="$TEST_ROOT/logs"
MANAGE_SCRIPT="$SCRIPT_DIR/manage_images.sh"

# Resolve exiftool: prefer bundled, fall back to system PATH.
EXIFTOOL=""
if [ -x "$SCRIPT_DIR/Image-ExifTool/exiftool" ]; then
    EXIFTOOL="$SCRIPT_DIR/Image-ExifTool/exiftool"
elif command -v exiftool >/dev/null 2>&1; then
    EXIFTOOL="$(command -v exiftool)"
fi

# Test-control flags
KEEP_ARTIFACTS="no"
for arg in "$@"; do
    case "$arg" in
        --keep) KEEP_ARTIFACTS="yes" ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
    esac
done

# Counters
ASSERTIONS_PASSED=0
ASSERTIONS_FAILED=0

# Fixed mtime for FileModifyDate-fallback files: 2020-01-15 10:30:00
# Used so we can assert these files land in test/output/2020/01/15/.
FALLBACK_MTIME="202001151030.00"
FALLBACK_YEAR="2020"
FALLBACK_MONTH="01"
FALLBACK_DAY="15"

# -----------------------------------------------------------------------------
# Output helpers
# -----------------------------------------------------------------------------
C_RESET="\033[0m"
C_GREEN="\033[32m"
C_RED="\033[31m"
C_YELLOW="\033[33m"
C_CYAN="\033[36m"
C_BOLD="\033[1m"

log_info()    { printf "${C_CYAN}[INFO]${C_RESET}  %s\n" "$*"; }
log_warn()    { printf "${C_YELLOW}[WARN]${C_RESET}  %s\n" "$*"; }
log_pass()    { printf "${C_GREEN}[PASS]${C_RESET}  %s\n" "$*"; ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1)); }
log_fail()    { printf "${C_RED}[FAIL]${C_RESET}  %s\n" "$*"; ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1)); }
log_section() { printf "\n${C_BOLD}===== %s =====${C_RESET}\n" "$*"; }

assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    if [ "$actual" = "$expected" ]; then
        log_pass "$desc (got $actual)"
    else
        log_fail "$desc (expected $expected, got $actual)"
    fi
}

assert_ge() {
    local actual="$1" minimum="$2" desc="$3"
    if [ "$actual" -ge "$minimum" ] 2>/dev/null; then
        log_pass "$desc (got $actual, expected ≥ $minimum)"
    else
        log_fail "$desc (expected ≥ $minimum, got $actual)"
    fi
}

assert_le() {
    local actual="$1" maximum="$2" desc="$3"
    if [ "$actual" -le "$maximum" ] 2>/dev/null; then
        log_pass "$desc (got $actual, expected ≤ $maximum)"
    else
        log_fail "$desc (expected ≤ $maximum, got $actual)"
    fi
}

assert_file_exists() {
    local file="$1" desc="$2"
    if [ -e "$file" ]; then
        log_pass "$desc"
    else
        log_fail "$desc (missing: $file)"
    fi
}

# -----------------------------------------------------------------------------
# Seed media: minimal valid JPEG (1x1 white) and PNG (1x1 transparent),
# decoded from inline base64 at init time. Exiftool can read and write EXIF
# tags into the JPEG seed, which is the basis for category 1 and 2 generators.
# -----------------------------------------------------------------------------
BASE_JPEG_B64="/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/2wBDAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQH/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAr/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEBAAAAAAAAAAAAAAAAAAAAAP/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AKpwB//Z"
BASE_PNG_B64="iVBORw0KGgoAAAANSUhEUgAAAAEAAAABAQAAAAA+UJ+JAAAACklEQVR4nGNiAAAABgADNjd8qAAAAABJRU5ErkJggg=="

decode_seed() {
    local b64="$1" out="$2"
    printf '%s' "$b64" | base64 -d > "$out"
}

# -----------------------------------------------------------------------------
# Low-level file factories
#
# The make_*  variants set every file to the fixed FALLBACK_MTIME. That is
# correct for categories whose date is supplied by EXIF or filename: the
# FileModifyDate fallback is irrelevant there. It is WRONG for categories that
# fall through to FileModifyDate, because identical content (same .base.jpg)
# + identical mtime would collide on the same target path and trigger mass
# MD5 dedup. Such categories use the *_unique variants below, which advance a
# global epoch counter so every file gets a distinct mtime and lands in its
# own target slot.
# -----------------------------------------------------------------------------
UNIQUE_MTIME_COUNTER=0
UNIQUE_MTIME_EPOCH_BASE=1577836800  # 2020-01-01 00:00:00 UTC

# IMPORTANT: this function must NOT be wrapped in command substitution.
# `$(next_unique_mtime)` would increment the counter in a subshell and discard
# the new value, so every call would return the same timestamp — exactly the
# pitfall that caused mass dedup in the first test runs. Use it through the
# make_*_unique_mtime helpers, which increment the counter in the parent shell
# and only use $(date ...) (a side-effect-free subshell) for formatting.
advance_unique_mtime_into() {
    # Writes the next timestamp into the named variable.
    UNIQUE_MTIME_COUNTER=$((UNIQUE_MTIME_COUNTER + 1))
    # 60-second spacing keeps target paths unique at second resolution and
    # gives 1440 distinct values per simulated day.
    local epoch=$((UNIQUE_MTIME_EPOCH_BASE + UNIQUE_MTIME_COUNTER * 60))
    printf -v "$1" '%s' "$(date -u -d "@$epoch" "+%Y%m%d%H%M.%S")"
}

make_jpeg() {
    cp "$INPUT_DIR/.base.jpg" "$1"
    set_mtime "$1" "$FALLBACK_MTIME"
}

make_jpeg_unique_mtime() {
    local _stamp
    cp "$INPUT_DIR/.base.jpg" "$1"
    advance_unique_mtime_into _stamp
    set_mtime "$1" "$_stamp"
}

make_png() {
    cp "$INPUT_DIR/.base.png" "$1"
    set_mtime "$1" "$FALLBACK_MTIME"
}

make_png_unique_mtime() {
    local _stamp
    cp "$INPUT_DIR/.base.png" "$1"
    advance_unique_mtime_into _stamp
    set_mtime "$1" "$_stamp"
}

make_empty_mp4() {
    local _stamp
    : > "$1"
    advance_unique_mtime_into _stamp
    set_mtime "$1" "$_stamp"
}

set_exif_date() {
    # Inject DateTimeOriginal and CreateDate. Format: "YYYY:MM:DD HH:MM:SS".
    local file="$1" date="$2"
    "$EXIFTOOL" -overwrite_original -DateTimeOriginal="$date" -CreateDate="$date" "$file" >/dev/null 2>&1
}

set_create_date_only() {
    # CreateDate without DateTimeOriginal — exercises the second-tier fallback.
    local file="$1" date="$2"
    "$EXIFTOOL" -overwrite_original -CreateDate="$date" "$file" >/dev/null 2>&1
}

set_mtime() {
    # touch -t format: [[CC]YY]MMDDhhmm[.ss]
    touch -t "$2" "$1"
}

ensure_dir() { mkdir -p "$1"; }

# -----------------------------------------------------------------------------
# Category generators — each one populates INPUT_DIR with a self-explanatory
# subset of files. Comments above each function describe which code path in
# manage_images.sh it exercises and what assertion (if any) downstream code
# relies on.
# -----------------------------------------------------------------------------

# C1: valid EXIF DateTimeOriginal across 2010..2024 — primary happy path.
gen_exif_valid() {
    local i year month day
    for i in $(seq 1 50); do
        year=$((2010 + (i % 15)))
        month=$(printf "%02d" $((1 + (i % 12))))
        day=$(printf "%02d" $((1 + (i % 28))))
        local f="$INPUT_DIR/photo_exif_${i}.jpg"
        make_jpeg "$f"
        set_exif_date "$f" "${year}:${month}:${day} 12:00:$(printf "%02d" $((i % 60)))"
    done
}

# C2: CreateDate only, no DateTimeOriginal — second-tier EXIF fallback.
gen_exif_create_date() {
    local i year month day
    for i in $(seq 1 25); do
        year=$((2015 + (i % 10)))
        month=$(printf "%02d" $((1 + (i % 12))))
        day=$(printf "%02d" $((1 + (i % 28))))
        local f="$INPUT_DIR/photo_create_${i}.jpg"
        make_jpeg "$f"
        set_create_date_only "$f" "${year}:${month}:${day} 13:00:00"
    done
}

# C3: Android pattern IMG_YYYYMMDD_HHMMSS — filename pattern 2.
gen_pattern_android() {
    local i year month day
    for i in $(seq 1 50); do
        year=$((2018 + (i % 7)))
        month=$(printf "%02d" $((1 + (i % 12))))
        day=$(printf "%02d" $((1 + (i % 28))))
        local f="$INPUT_DIR/IMG_${year}${month}${day}_$(printf "%06d" $((i * 100))).jpg"
        make_jpeg "$f"
    done
}

# C4: Google Pixel pattern PXL_YYYYMMDD_HHMMSSsss — filename pattern 2 variant.
gen_pattern_pixel() {
    local i year month day
    for i in $(seq 1 30); do
        year=$((2020 + (i % 5)))
        month=$(printf "%02d" $((1 + (i % 12))))
        day=$(printf "%02d" $((1 + (i % 28))))
        local f="$INPUT_DIR/PXL_${year}${month}${day}_$(printf "%06d" $((i * 100)))123.jpg"
        make_jpeg "$f"
    done
}

# C5: Facebook FB_IMG_<unix_ts> — filename pattern 1 (FB_IMG / FB_VID).
gen_pattern_facebook() {
    local i
    for i in $(seq 1 20); do
        # epoch 1577836800 = 2020-01-01 00:00:00 UTC; spread by i days
        local ts=$((1577836800 + i * 86400))
        local f="$INPUT_DIR/FB_IMG_${ts}.jpg"
        make_jpeg "$f"
    done
}

# C6: Android screenshot dash pattern Screenshot_YYYYMMDD-HHMMSS — pattern 4.
gen_pattern_screenshot_dash() {
    local i year month day
    for i in $(seq 1 30); do
        year=$((2021 + (i % 4)))
        month=$(printf "%02d" $((1 + (i % 12))))
        day=$(printf "%02d" $((1 + (i % 28))))
        local f="$INPUT_DIR/Screenshot_${year}${month}${day}-$(printf "%06d" $((i * 100))).png"
        make_png "$f"
    done
}

# C7: DYTCamera dash-everywhere YYYY-MM-DD-HH-MM-SS — filename pattern 6.
gen_pattern_dytcamera() {
    local i year month day h m s
    for i in $(seq 1 20); do
        year=$((2022 + (i % 3)))
        month=$(printf "%02d" $((1 + (i % 12))))
        day=$(printf "%02d" $((1 + (i % 28))))
        h=$(printf "%02d" $((i % 24)))
        m=$(printf "%02d" $((i % 60)))
        s=$(printf "%02d" $(((i * 7) % 60)))
        local f="$INPUT_DIR/${year}-${month}-${day}-${h}-${m}-${s}-$(printf "%05x" $((i * 100))).jpg"
        make_jpeg "$f"
    done
}

# C8: Signal pattern signal-YYYY-MM-DD-HHMMSS — filename pattern 7.
gen_pattern_signal() {
    local i year month day
    for i in $(seq 1 20); do
        year=$((2021 + (i % 4)))
        month=$(printf "%02d" $((1 + (i % 12))))
        day=$(printf "%02d" $((1 + (i % 28))))
        local f="$INPUT_DIR/signal-${year}-${month}-${day}-$(printf "%06d" $((i * 100)))${i}.jpg"
        make_jpeg "$f"
    done
}

# C9: WhatsApp date-only IMG-YYYYMMDD-WAxxxx — filename pattern 8 (anchored).
gen_pattern_whatsapp() {
    local i year month day
    for i in $(seq 1 30); do
        year=$((2019 + (i % 6)))
        month=$(printf "%02d" $((1 + (i % 12))))
        day=$(printf "%02d" $((1 + (i % 28))))
        local f="$INPUT_DIR/IMG-${year}${month}${day}-WA$(printf "%04d" "$i").jpg"
        make_jpeg "$f"
    done
}

# C10: Dot-separated YYYYMMDD.HHMMSS — filename pattern 3.
gen_pattern_dotted() {
    local i year month day
    for i in $(seq 1 20); do
        year=$((2020 + (i % 5)))
        month=$(printf "%02d" $((1 + (i % 12))))
        day=$(printf "%02d" $((1 + (i % 28))))
        local f="$INPUT_DIR/IMG_${year}${month}${day}.$(printf "%06d" $((i * 100))).jpg"
        make_jpeg "$f"
    done
}

# C11: ISO underscore YYYY-MM-DD_HH-MM-SS — filename pattern 5.
gen_pattern_iso() {
    local i year month day
    for i in $(seq 1 20); do
        year=$((2019 + (i % 6)))
        month=$(printf "%02d" $((1 + (i % 12))))
        day=$(printf "%02d" $((1 + (i % 28))))
        local h=$(printf "%02d" $((i % 24)))
        local m=$(printf "%02d" $((i % 60)))
        local s=$(printf "%02d" $(((i * 11) % 60)))
        local f="$INPUT_DIR/photo_${year}-${month}-${day}_${h}-${m}-${s}.jpg"
        make_jpeg "$f"
    done
}

# C12: files inside WhatsApp/ subdir — exercises --keepSourceTag matching and
# FileModifyDate fallback (no recognisable filename pattern, no EXIF).
# Uses unique mtimes so files spread across distinct target paths instead of
# colliding into a single MD5 dedup heap.
gen_in_whatsapp_dir() {
    ensure_dir "$INPUT_DIR/WhatsApp/Media"
    local i
    for i in $(seq 1 30); do
        make_jpeg_unique_mtime "$INPUT_DIR/WhatsApp/Media/random_$(printf "%04d" "$i").jpg"
    done
}

# C13: files inside Signal/ subdir.
gen_in_signal_dir() {
    ensure_dir "$INPUT_DIR/Signal/"
    local i
    for i in $(seq 1 20); do
        make_jpeg_unique_mtime "$INPUT_DIR/Signal/img_$(printf "%04d" "$i").jpg"
    done
}

# C14: files inside Screenshots/ subdir.
gen_in_screenshots_dir() {
    ensure_dir "$INPUT_DIR/Screenshots"
    local i
    for i in $(seq 1 20); do
        make_png_unique_mtime "$INPUT_DIR/Screenshots/cap_$(printf "%04d" "$i").png"
    done
}

# C15: UTF-8 path Wiadomości/ — verifies non-ASCII directory handling.
gen_in_wiadomosci_dir() {
    ensure_dir "$INPUT_DIR/Wiadomości/MmsCamera"
    local i
    for i in $(seq 1 10); do
        make_jpeg_unique_mtime "$INPUT_DIR/Wiadomości/MmsCamera/msg_$(printf "%04d" "$i").jpg"
    done
}

# C16: pre-existing YYYY/MM/DD path — exercises DirectoryPath fallback.
# All 10 files share the same DirectoryPath date (2023-05-12 00:00:00) and
# identical content → they intentionally collide and exercise the dedup logic
# (~9 dedup events expected from this category).
gen_in_dated_dir() {
    ensure_dir "$INPUT_DIR/2023/05/12"
    local i
    for i in $(seq 1 10); do
        make_jpeg "$INPUT_DIR/2023/05/12/leftover_$(printf "%04d" "$i").jpg"
    done
}

# C17: completely unparseable filenames — FileModifyDate fallback.
gen_no_date() {
    local i
    for i in $(seq 1 20); do
        make_jpeg_unique_mtime "$INPUT_DIR/random_$(printf "%04d" "$i").jpg"
    done
}

# C18: Pattern-8 trap — 14 contiguous digits whose FIRST 8 digits form a
# plausible date (20990123 = 2099-01-23). With the broken (unanchored)
# pattern 8, exiftool would have parsed this as 2099-01-23 and dropped the
# files in output/2099/01/23/. With the regex anchor fix, the 14-digit run
# is rejected (not bounded by non-digits at the 8-digit position), so files
# fall through to FileModifyDate (unique per file, late 2019).
#
# Assertion: zero files in output/2099/  →  trap fix is in effect.
gen_pattern8_trap() {
    local i
    for i in $(seq 1 10); do
        local f="$INPUT_DIR/IMG_2099012314302${i}.jpg"
        make_jpeg_unique_mtime "$f"
    done
}

# C19: filename with invalid month/day digits — pattern 8 sanity check must
# reject; downstream falls back to FileModifyDate.
gen_invalid_filename_dates() {
    local i
    for i in $(seq 1 10); do
        # Month 13 / day 32 — both fail the sanity regex inside pattern 8.
        local f="$INPUT_DIR/IMG-2023133${i}-WA0001.jpg"
        make_jpeg_unique_mtime "$f"
    done
}

# C20: 10 pairs of identical-content files — exercises MD5 dedup logic.
# Each pair has identical EXIF date AND identical bytes, so both pair members
# generate the same target path; the second one collides → MD5 match → SKIP
# (and in move mode, source is removed). Expect log_removed_duplicates.log
# to have ≥ 10 entries after the run.
gen_duplicates() {
    local i day
    for i in $(seq 1 10); do
        day=$(printf "%02d" "$i")
        local a="$INPUT_DIR/dup_${i}_a.jpg"
        local b="$INPUT_DIR/dup_${i}_b.jpg"
        make_jpeg "$a"
        set_exif_date "$a" "2020:04:${day} 11:00:00"
        cp "$a" "$b"
        set_mtime "$b" "$FALLBACK_MTIME"
    done
}

# C21: Synology thumbnails — default ignore pattern. Should NOT reach EXIF
# analysis; must be listed in log_ignored_files.log instead.
gen_synology_thumbs() {
    local i
    for i in $(seq 1 10); do
        make_jpeg "$INPUT_DIR/SYNOPHOTO_THUMB_$(printf "%04d" "$i").jpg"
    done
}

# C22: empty .mp4 / .mov dummies — extension recognition + FileModifyDate.
gen_video_dummy() {
    local i
    for i in $(seq 1 12); do
        make_empty_mp4 "$INPUT_DIR/video_$(printf "%04d" "$i").mp4"
    done
    for i in $(seq 1 8); do
        make_empty_mp4 "$INPUT_DIR/clip_$(printf "%04d" "$i").mov"
    done
}

# C23: XMP sidecar — Adobe/Lightroom/Darktable metadata fallback.
gen_xmp_sidecar() {
    local i year month day
    for i in $(seq 1 5); do
        year=$((2017 + i))
        month=$(printf "%02d" $((i + 3)))
        day=$(printf "%02d" $((i + 10)))
        local jpg="$INPUT_DIR/sidecar_${i}.jpg"
        local xmp="$INPUT_DIR/sidecar_${i}.xmp"
        make_jpeg "$jpg"
        cat > "$xmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<x:xmpmeta xmlns:x="adobe:ns:meta/">
  <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
    <rdf:Description xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                     xmp:CreateDate="${year}-${month}-${day}T15:30:00"/>
  </rdf:RDF>
</x:xmpmeta>
EOF
    done
}

# -----------------------------------------------------------------------------
# Orchestration
# -----------------------------------------------------------------------------
preflight() {
    log_section "Preflight checks"

    if [ -z "$EXIFTOOL" ]; then
        log_fail "exiftool not found (looked at $SCRIPT_DIR/Image-ExifTool/exiftool and \$PATH)"
        log_info "Run manage_images.sh on any non-empty source dir to trigger auto-download, or install exiftool."
        exit 2
    fi
    log_info "Using exiftool: $EXIFTOOL ($($EXIFTOOL -ver 2>/dev/null))"

    if [ ! -x "$MANAGE_SCRIPT" ]; then
        log_fail "manage_images.sh not executable at: $MANAGE_SCRIPT"
        exit 2
    fi
    log_info "Using manage_images.sh: $MANAGE_SCRIPT"

    for cmd in base64 find md5sum touch date; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_fail "Required command not found: $cmd"
            exit 2
        fi
    done
}

init_corpus() {
    log_section "Initialising test corpus in $INPUT_DIR"

    rm -rf "$TEST_ROOT"
    ensure_dir "$INPUT_DIR"
    ensure_dir "$OUTPUT_DIR"
    ensure_dir "$TEST_LOG_DIR"

    # Decode seed media (dot-prefixed so they aren't matched by IMAGE_EXTENSIONS).
    decode_seed "$BASE_JPEG_B64" "$INPUT_DIR/.base.jpg"
    decode_seed "$BASE_PNG_B64"  "$INPUT_DIR/.base.png"

    # Verify the seed JPEG is valid enough for exiftool to write EXIF into it.
    if ! "$EXIFTOOL" -overwrite_original -DateTimeOriginal="2000:01:01 00:00:00" \
            "$INPUT_DIR/.base.jpg" >/dev/null 2>&1; then
        log_fail "Seed JPEG is not writable by exiftool — base64 may be corrupt"
        exit 2
    fi
    # Reset the seed (remove our probe EXIF) so categories start clean.
    "$EXIFTOOL" -overwrite_original -all= "$INPUT_DIR/.base.jpg" >/dev/null 2>&1

    log_info "Generating ~500 files across 23 categories..."
    local gen_start; gen_start=$(date +%s)

    gen_exif_valid               # 50  C1
    gen_exif_create_date         # 25  C2
    gen_pattern_android          # 50  C3
    gen_pattern_pixel            # 30  C4
    gen_pattern_facebook         # 20  C5
    gen_pattern_screenshot_dash  # 30  C6
    gen_pattern_dytcamera        # 20  C7
    gen_pattern_signal           # 20  C8
    gen_pattern_whatsapp         # 30  C9
    gen_pattern_dotted           # 20  C10
    gen_pattern_iso              # 20  C11
    gen_in_whatsapp_dir          # 30  C12
    gen_in_signal_dir            # 20  C13
    gen_in_screenshots_dir       # 20  C14
    gen_in_wiadomosci_dir        # 10  C15
    gen_in_dated_dir             # 10  C16
    gen_no_date                  # 20  C17
    gen_pattern8_trap            # 10  C18
    gen_invalid_filename_dates   # 10  C19
    gen_duplicates               # 20  C20
    gen_synology_thumbs          # 10  C21
    gen_video_dummy              # 20  C22
    gen_xmp_sidecar              # 5   C23 (+ 5 .xmp sidecars)

    # Remove the dot-prefixed seeds — they aren't multimedia and shouldn't be
    # processed by manage_images.sh, but tidying makes the corpus easier to
    # reason about.
    rm -f "$INPUT_DIR/.base.jpg" "$INPUT_DIR/.base.png"

    local gen_end; gen_end=$(date +%s)
    local total_files
    total_files=$(find "$INPUT_DIR" -type f | wc -l)
    local media_files
    media_files=$(find "$INPUT_DIR" -type f \( \
        -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' \
        -o -iname '*.bmp' -o -iname '*.tiff' -o -iname '*.tif' -o -iname '*.heic' \
        -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.mkv' \
        \) | wc -l)

    # Count images vs videos separately for clearer reporting
    local image_files video_files
    image_files=$(find "$INPUT_DIR" -type f \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' -o -iname '*.bmp' -o -iname '*.tiff' -o -iname '*.tif' -o -iname '*.heic' \) | wc -l)
    video_files=$(find "$INPUT_DIR" -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.mkv' \) | wc -l)

    # Count files that contain embedded metadata timestamps (EXIF/XMP fields)
    # and count standalone XMP sidecars separately.
    local media_files_with_metadata=0
    local _meta_out
    _meta_out=$(find "$INPUT_DIR" -type f \( \
        -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' \
        -o -iname '*.bmp' -o -iname '*.tiff' -o -iname '*.tif' -o -iname '*.heic' \
        -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.mkv' \
        \) -print0 | xargs -0 -n 500 "$EXIFTOOL" -T -DateTimeOriginal -CreateDate -XMP:CreateDate 2>/dev/null || true)
    if [ -n "$_meta_out" ]; then
        while IFS= read -r _l; do
            if printf '%s' "$_l" | grep -qE '[0-9]'; then
                media_files_with_metadata=$((media_files_with_metadata + 1))
            fi
        done <<< "$_meta_out"
    fi
    local xmp_sidecars
    xmp_sidecars=$(find "$INPUT_DIR" -type f -iname '*.xmp' | wc -l)
    local metadata_files_total=$((media_files_with_metadata + xmp_sidecars))

    log_info "Generation done in $((gen_end - gen_start))s — total files: $total_files, multimedia: $media_files"
    log_info "Created images: $image_files, videos: $video_files, embedded metadata files: $media_files_with_metadata, XMP sidecars: $xmp_sidecars, total metadata-bearing files: $metadata_files_total"
    INIT_TOTAL_FILES="$total_files"
    INIT_MEDIA_FILES="$media_files"
    INIT_IMAGE_FILES="$image_files"
    INIT_VIDEO_FILES="$video_files"
    INIT_MEDIA_FILES_WITH_METADATA="$media_files_with_metadata"
    INIT_XMP_SIDECARS="$xmp_sidecars"
    INIT_METADATA_FILES_TOTAL="$metadata_files_total"
}

run_test() {
    log_section "Running manage_images.sh --task=move"

    local run_start; run_start=$(date +%s)

    # Pipe through cat to keep stdout in script's log; suppress detailed stats
    # for compactness (the script writes everything to TEST_LOG_DIR/logs/ anyway).
    LOG_DIR="$TEST_LOG_DIR" "$MANAGE_SCRIPT" --task=move "$INPUT_DIR" "$OUTPUT_DIR" \
        > "$TEST_LOG_DIR/run.stdout" 2> "$TEST_LOG_DIR/run.stderr"
    RUN_EXIT_CODE=$?

    local run_end; run_end=$(date +%s)
    RUN_ELAPSED=$((run_end - run_start))

    log_info "manage_images.sh exited with code $RUN_EXIT_CODE in ${RUN_ELAPSED}s"

    if [ "$RUN_EXIT_CODE" -ne 0 ]; then
        log_warn "manage_images.sh failed; dumping captured output for diagnosis"
        printf "\n[MANAGE_STDOUT]\n"
        if [ -s "$TEST_LOG_DIR/run.stdout" ]; then
            cat "$TEST_LOG_DIR/run.stdout"
        else
            printf "(empty)\n"
        fi
        printf "\n[MANAGE_STDERR]\n"
        if [ -s "$TEST_LOG_DIR/run.stderr" ]; then
            cat "$TEST_LOG_DIR/run.stderr"
        else
            printf "(empty)\n"
        fi
        printf "\n[LOG DIR CONTENTS]\n"
        find "$TEST_LOG_DIR" -maxdepth 2 -type d | sort || true
    fi

    # Locate the timestamped log subdir produced by manage_images.sh
    LATEST_LOG_SUBDIR=$(find "$TEST_LOG_DIR/logs" -maxdepth 1 -mindepth 1 -type d 2>/dev/null \
        | sort | tail -1)
    log_info "manage_images.sh logs at: $LATEST_LOG_SUBDIR"

    
}

# -----------------------------------------------------------------------------
# Assertions
# -----------------------------------------------------------------------------
count_files_in() {
    # Count multimedia files anywhere under the given path.
    find "$1" -type f \( \
        -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.gif' \
        -o -iname '*.bmp' -o -iname '*.tiff' -o -iname '*.tif' -o -iname '*.heic' \
        -o -iname '*.mp4' -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.mkv' \
        \) 2>/dev/null | wc -l
}

count_log_lines() {
    [ -f "$1" ] && wc -l < "$1" || echo 0
}

verify() {
    log_section "Verifying outcomes"

    # A0: the run itself must have exited cleanly.
    assert_eq "$RUN_EXIT_CODE" "0" "manage_images.sh exited 0"

    # A1: output directory tree exists and contains the exact expected media files.
    # Deterministic corpus should produce 445 copied/moved multimedia files.
    local out_count; out_count=$(count_files_in "$OUTPUT_DIR")
    assert_eq "$out_count" "445" "output contains 445 multimedia files"

    # A2: total OUT + ignored + dedup-skipped should exactly equal INIT_MEDIA_FILES.
    if [ -z "${LATEST_LOG_SUBDIR:-}" ]; then
        log_fail "Could not locate manage_images.sh log subdirectory"
        return
    fi

    local ignored; ignored=$(count_log_lines "$LATEST_LOG_SUBDIR/log_ignored_files.log")
    local failed;  failed=$(count_log_lines  "$LATEST_LOG_SUBDIR/log_failed_files.log")
    local removed; removed=$(count_log_lines "$LATEST_LOG_SUBDIR/log_removed_duplicates.log")
    local skipped; skipped=$(count_log_lines "$LATEST_LOG_SUBDIR/log_skipped_files.log")
    log_info "Run accounting: out=$out_count ignored=$ignored skipped=$skipped removed=$removed failed=$failed"

    local accounted=$((out_count + ignored + skipped))
    if [ "$accounted" -eq "$INIT_MEDIA_FILES" ] 2>/dev/null; then
        log_pass "Accounting exact: out+ignored+skipped=$accounted"
    else
        log_fail "Accounting off: out+ignored+skipped=$accounted, expected $INIT_MEDIA_FILES"
    fi

    # A3: SYNOPHOTO_THUMB_ ignore — exactly 10 entries, no thumbs in output.
    assert_eq "$ignored" "10" "log_ignored_files.log contains 10 entries (SYNOPHOTO_THUMB_)"
    local thumbs_in_out; thumbs_in_out=$(find "$OUTPUT_DIR" -name 'SYNOPHOTO_THUMB_*' 2>/dev/null | wc -l)
    assert_eq "$thumbs_in_out" "0" "no SYNOPHOTO_THUMB_ files in output"

    # A4: MD5 dedup — deterministic corpus produces exactly 45 removed-source entries.
    assert_eq "$removed" "45" "log_removed_duplicates.log records 45 dedup removals"

    # A5: pattern-8 trap fix — trap filenames are IMG_2099012314302N.jpg.
    # With the broken (unanchored) pattern 8, they'd land in output/2099/01/23/.
    # With the fix, pattern 8 won't match a 14-digit run, so they fall through
    # to FileModifyDate (year 2019/2020). Zero files in output/2099/ proves
    # the fix is active.
    local files_in_2099; files_in_2099=$(find "$OUTPUT_DIR/2099" -type f 2>/dev/null | wc -l)
    assert_eq "$files_in_2099" "0" "Pattern-8 trap fix: 0 files in output/2099/ (would be 10 if regressed)"

    # A6: no future-dated directories in general.
    local future_dirs
    future_dirs=$(find "$OUTPUT_DIR" -maxdepth 1 -mindepth 1 -type d \
        -regextype posix-extended -regex '.*/20[3-9][0-9]$' 2>/dev/null | wc -l)
    assert_eq "$future_dirs" "0" "no future-dated top-level year directories"

    # A7: EXIF write-back log exists and has exactly 210 SUCCESS entries.
    local exif_writes; exif_writes=$(grep -c '^\[SUCCESS\]' \
        "$LATEST_LOG_SUBDIR/log_exif_updates.log" 2>/dev/null || echo 0)
    assert_eq "$exif_writes" "210" "210 successful EXIF write-backs from filename parsing"

    # A8: source dir after --task=move should retain only ignored thumbs and .xmp sidecars.
    # That is exactly 15 files: 10 SYNOPHOTO_THUMB_ and 5 .xmp sidecars.
    local residual; residual=$(find "$INPUT_DIR" -type f | wc -l)
    assert_eq "$residual" "15" "15 files remain in source after move"

    # A9: failed-files log should contain no entries for this deterministic corpus.
    assert_eq "$failed" "0" "log_failed_files.log has 0 entries"

    # A10: status.log generated.
    assert_file_exists "$LATEST_LOG_SUBDIR/status.log" "status.log written"
}

cleanup() {
    log_section "Cleanup"
    if [ "$KEEP_ARTIFACTS" = "yes" ]; then
        log_info "Keeping artifacts at $TEST_ROOT (--keep was set)"
        return
    fi
    if [ "$ASSERTIONS_FAILED" -gt 0 ]; then
        log_info "Keeping artifacts at $TEST_ROOT for inspection (failures > 0)"
        return
    fi
    rm -rf "$TEST_ROOT"
    log_info "Removed $TEST_ROOT"
}

summary() {
    log_section "SUMMARY"
    local total=$((ASSERTIONS_PASSED + ASSERTIONS_FAILED))
    # Use %b (not %s) so the ANSI escape variables get interpreted; %s would
    # print the literal "\033[32m..." backslash sequence.
    printf "Assertions: %d total, %b%d passed%b, %b%d failed%b\n" \
        "$total" "$C_GREEN" "$ASSERTIONS_PASSED" "$C_RESET" \
        "$C_RED" "$ASSERTIONS_FAILED" "$C_RESET"
    printf "Run time (manage_images.sh): %ds\n" "$RUN_ELAPSED"
    printf "Total test time: %ds\n" "$TOTAL_ELAPSED"
    printf "Generated images: %d, videos: %d\n" "$INIT_IMAGE_FILES" "$INIT_VIDEO_FILES"
    printf "Embedded metadata media files: %d, XMP sidecars: %d, total metadata-bearing files: %d\n" \
        "$INIT_MEDIA_FILES_WITH_METADATA" "$INIT_XMP_SIDECARS" "$INIT_METADATA_FILES_TOTAL"
    if [ "$ASSERTIONS_FAILED" -eq 0 ]; then
        printf "%bOK — all assertions passed%b\n" "${C_GREEN}${C_BOLD}" "$C_RESET"
    else
        printf "%bFAIL — %d assertion(s) failed%b\n" "${C_RED}${C_BOLD}" "$ASSERTIONS_FAILED" "$C_RESET"
        printf "Inspect logs at: %s\n" "$LATEST_LOG_SUBDIR"
        printf "Inspect output at: %s\n" "$OUTPUT_DIR"
    fi
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
    local test_start; test_start=$(date +%s)

    preflight
    init_corpus
    run_test
    verify
    cleanup

    local test_end; test_end=$(date +%s)
    TOTAL_ELAPSED=$((test_end - test_start))
    summary

    [ "$ASSERTIONS_FAILED" -eq 0 ] && exit 0 || exit 1
}

# Defaults for variables that the summary touches even on early exit.
RUN_EXIT_CODE=0
RUN_ELAPSED=0
TOTAL_ELAPSED=0
LATEST_LOG_SUBDIR=""
INIT_TOTAL_FILES=0
INIT_MEDIA_FILES=0
INIT_IMAGE_FILES=0
INIT_VIDEO_FILES=0
INIT_MEDIA_FILES_WITH_METADATA=0
INIT_XMP_SIDECARS=0
INIT_METADATA_FILES_TOTAL=0

main
