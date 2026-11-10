#!/usr/bin/env bash
#
# dump-dvd.sh — defensively run `dvdbackup -M` on a DVD.
#
# Defaults: input  = first detected /dev/sr*
#           output = ./output
#
# Usage:
#   ./dump-dvd.sh [-i DEVICE] [-o OUTDIR] [-y] [-h]
#
# Options:
#   -i, --input DEVICE   DVD block device (default: first /dev/sr*)
#   -o, --output DIR     Output directory (default: ./output)
#   -y, --yes            Auto-confirm the apt install prompt if dvdbackup is missing
#   -h, --help           Show this help
#
set -euo pipefail

prog="$(basename "$0")"

usage() { sed -n '3,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
err()   { echo "$prog: error: $*" >&2; }
info()  { echo "$prog: $*"; }
have()  { command -v "$1" >/dev/null 2>&1; }

ask_yn() {
    local prompt="$1" default="${2:-y}" reply
    while true; do
        if ! read -r -p "$prompt [$([ "$default" = y ] && echo Y/n || echo y/N)] " reply </dev/tty; then
            err "no TTY available for prompt; rerun in an interactive shell or pass -y."
            exit 1
        fi
        reply="${reply:-$default}"
        case "${reply,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
        esac
    done
}

# ---- arg parsing ----
INPUT=""
OUTPUT="./output"
ASSUME_YES=0
while [ $# -gt 0 ]; do
    case "$1" in
        -i|--input)  INPUT="$2";  shift 2 ;;
        -o|--output) OUTPUT="$2"; shift 2 ;;
        -y|--yes)    ASSUME_YES=1; shift ;;
        -h|--help)   usage 0 ;;
        *)           echo "$prog: unknown option: $1" >&2; usage 1 ;;
    esac
done

# expand a leading ~ in OUTPUT
OUTPUT="${OUTPUT/#\~/$HOME}"

# ---- detect DVD drive ----
if [ -z "$INPUT" ]; then
    drives=()
    for d in /dev/sr*; do
        [ -b "$d" ] && drives+=("$d")
    done
    # fallback: lsblk rom devices
    if [ "${#drives[@]}" -eq 0 ] && have lsblk; then
        while IFS= read -r name; do
            [ -n "$name" ] && [ -b "/dev/$name" ] && drives+=("/dev/$name")
        done < <(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2=="rom"{print $1}')
    fi
    if [ "${#drives[@]}" -eq 0 ]; then
        err "no DVD drive detected (looked for /dev/sr* and lsblk rom devices)."
        err "specify one with: -i /dev/sr0"
        exit 1
    fi
    INPUT="${drives[0]}"
    [ "${#drives[@]}" -gt 1 ] && info "multiple drives found: ${drives[*]}; using $INPUT (override with -i)."
fi

# ---- validate device ----
if [ ! -b "$INPUT" ]; then
    err "'$INPUT' is not a block device."
    exit 1
fi
info "input device: $INPUT"

# ---- check media present ----
if have blockdev; then
    size_bytes="$(sudo blockdev --getsize64 "$INPUT" 2>/dev/null || echo 0)"
    if ! [[ "$size_bytes" =~ ^[0-9]+$ ]] || [ "$size_bytes" -le 0 ]; then
        err "no media in $INPUT (drive reports zero size). Insert a DVD and retry."
        exit 1
    fi
    info "media size: $((size_bytes / 1024 / 1024)) MiB"
else
    info "blockdev not available; skipping media-presence check."
fi

# ---- unmount if mounted ----
if have findmnt && findmnt --source "$INPUT" >/dev/null 2>&1; then
    info "$INPUT is mounted; unmounting."
    sudo umount "$INPUT" || { err "failed to unmount $INPUT"; exit 1; }
fi

# ---- prepare output dir ----
mkdir -p "$OUTPUT"
if [ ! -w "$OUTPUT" ]; then
    err "output directory '$OUTPUT' is not writable."
    exit 1
fi
OUTPUT="$(cd "$OUTPUT" && pwd)"
info "output directory: $OUTPUT"

# ---- check dvdbackup availability, offer to install ----
if ! have dvdbackup; then
    info "dvdbackup is not installed."
    if ! have apt-get; then
        err "this auto-installer targets Debian/Ubuntu (apt)."
        err "Fedora: sudo dnf install dvdbackup libdvdcss"
        err "Arch:   sudo pacman -S dvdbackup libdvdcss"
        exit 1
    fi
    if [ "$ASSUME_YES" -eq 0 ]; then
        if ! ask_yn "Install libdvd-pkg + dvdbackup now via apt? (needs sudo, internet, build tools for libdvdcss)" "y"; then
            err "cannot continue without dvdbackup. Aborting."
            exit 1
        fi
    fi
    info "running apt install sequence:"
    info "  sudo apt install libdvd-pkg && sudo dpkg-reconfigure libdvd-pkg && sudo apt install dvdbackup"
    sudo apt-get update
    # libdvd-pkg builds libdvdcss2 from downloaded source, so it needs the build deps
    sudo apt-get install -y libdvd-pkg dpkg-dev build-essential
    sudo dpkg-reconfigure libdvd-pkg
    sudo apt-get install -y dvdbackup
    if ! have dvdbackup; then
        err "install finished but 'dvdbackup' is still not on PATH."
        exit 1
    fi
fi

# ---- soft check: libdvdcss2 (CSS decryption) ----
have_libdvdcss=0
if have ldconfig && ldconfig -p 2>/dev/null | grep -q 'libdvdcss\.so'; then
    have_libdvdcss=1
fi
if [ "$have_libdvdcss" -eq 0 ] && \
   find /usr/lib /usr/local/lib -maxdepth 2 -name 'libdvdcss.so*' 2>/dev/null | grep -q .; then
    have_libdvdcss=1
fi
if [ "$have_libdvdcss" -eq 0 ]; then
    info "WARNING: libdvdcss2 not detected. CSS-encrypted commercial DVDs will fail to decrypt."
    info "         install with: sudo apt install libdvd-pkg && sudo dpkg-reconfigure libdvd-pkg"
fi

# ---- run dvdbackup ----
info "running: dvdbackup -M -i $INPUT -o $OUTPUT"
set +e
dvdbackup -M -i "$INPUT" -o "$OUTPUT"
rc=$?
set -e
if [ "$rc" -ne 0 ]; then
    err "dvdbackup exited with code $rc."
    exit "$rc"
fi

info "done. dvdbackup wrote the disc's VIDEO_TS tree under: $OUTPUT/"
ls -la -- "$OUTPUT" 2>/dev/null || true
