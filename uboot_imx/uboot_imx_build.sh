#!/bin/bash
set -euo pipefail

# Resolve script directory
SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
  SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  [[ "$SCRIPT_SOURCE" != /* ]] && SCRIPT_SOURCE="$SCRIPT_DIR/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_SOURCE")" && pwd)"

ENV_SCRIPT_PATH="$SCRIPT_DIR/uboot_imx_env.sh"
if [ ! -f "$ENV_SCRIPT_PATH" ]; then
  echo "Error: $ENV_SCRIPT_PATH not found"
  exit 1
fi
source "$ENV_SCRIPT_PATH"

exec > >(tee -a "$LOGFILE") 2>&1

VERBOSE=false
DRY_RUN=false
BUILD_TARGET="all"
DEVICE=""
WORKDIR=""

usage() {
  cat <<EOF
Usage: $0 -w <workdir> [-d <device>] [-t <target>] [-n] [-v] [-h]
  -w  Working directory (required)
  -d  Block device (only used by -t flash)
  -t  Target: prep | uboot | atf | image | flash | all | clean:xxx  (default: all)
  -b  Same as -t (compatibility)
  -n  Dry-run flash
  -v  Verbose
EOF
  exit 1
}

while getopts "w:d:t:b:nvh" opt; do
  case $opt in
    w) WORKDIR=$OPTARG ;;
    d) DEVICE=$OPTARG ;;
    t) BUILD_TARGET=$OPTARG ;;
    b) BUILD_TARGET=$OPTARG ;;
    n) DRY_RUN=true ;;
    v) VERBOSE=true ;;
    h|*) usage ;;
  esac
done

[[ -z "$WORKDIR" ]] && usage
mkdir -p "$WORKDIR"
WORKDIR=$(realpath "$WORKDIR")

log() { echo "[$(date '+%F %T')] $*"; }

check_deps() {
  local missing=()
  for c in git wget make gcc dd; do
    command -v "$c" &>/dev/null || missing+=("$c")
  done
  if ((${#missing[@]})); then
    echo "Missing: ${missing[*]}"
    read -rp "Install with apt? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] && sudo apt-get install -y "${missing[@]}" || exit 1
  fi
}

clone_or_update() {
  local url=$1 branch=$2 dest=$3
  if [ -d "$dest/.git" ]; then
    log "Updating $dest ($branch)"
    git -C "$dest" fetch origin
    git -C "$dest" checkout "$branch"
    git -C "$dest" pull --ff-only origin "$branch" || true
  else
    log "Cloning $url → $dest"
    git clone --branch "$branch" --depth 1 "$url" "$dest"
  fi
}

prepare_ddr() {
  local tools="$WORKDIR/$UBOOT_TOOLS_DIR"
  mkdir -p "$tools"
  cd "$tools"
  local fw="firmware-imx-${DDR_FIRMWARE_VERSION}.bin"
  if [ ! -f "$fw" ]; then
    log "Downloading DDR firmware..."
    wget -q --show-progress -O "$fw" "$DDR_FIRMWARE_URL"
    chmod +x "$fw"
    ./"$fw" --auto-accept || true
  fi
  # Copy the actual DDR blobs
  find firmware-imx-${DDR_FIRMWARE_VERSION}/firmware/ddr/synopsys -name "*.bin" -exec cp {} . \;
  log "DDR firmware ready"
}

build_uboot() {
  local dir="$WORKDIR/uboot-imx"
  clone_or_update "$UBOOT_REPO" "$UBOOT_BRANCH" "$dir"
  cd "$dir"
  command -v ccache &>/dev/null && ccache --max-size=20G || true
  export ARCH=$ARCH_ARM64 CROSS_COMPILE=$CROSS_COMPILE_ARM64
  make mrproper
  make "$UBOOT_DEFCONFIG"
  make -j"$(nproc)"
  log "U-Boot built"
}

build_atf() {
  local tools="$WORKDIR/$UBOOT_TOOLS_DIR"
  local atf="$tools/imx-atf"
  local bsp="$tools/meta-variscite-bsp"
  local mk="$tools/imx-mkimage"

  mkdir -p "$tools"
  clone_or_update "$ATF_REPO" "$ATF_BRANCH" "$atf"
  clone_or_update "$META_VARISCITE_BSP_REPO" "$META_VARISCITE_BSP_BRANCH" "$bsp"
  clone_or_update "$IMX_MKIMAGE_REPO" "$IMX_MKIMAGE_BRANCH" "$mk"

  # Apply Variscite patches
  cd "$mk"
  for p in \
    "$bsp/recipes-bsp/imx-mkimage/imx-boot/0001-iMX8M-soc-allow-dtb-override.patch" \
    "$bsp/recipes-bsp/imx-mkimage/imx-boot/0002-iMX8M-soc-change-padding-of-DDR4-and-LPDDR4-DMEM-fir.patch"
  do
    if [ -f "$p" ] && git apply --check "$p" &>/dev/null; then
      log "Applying $(basename "$p")"
      git apply "$p"
    fi
  done

  # Build ATF
  cd "$atf"
  export ARCH=$ARCH_ARM64 CROSS_COMPILE=$CROSS_COMPILE_ARM64
  unset LDFLAGS
  make PLAT=imx8mp bl31 -j"$(nproc)"
  cp build/imx8mp/release/bl31.bin "$tools/"
  log "ATF (bl31.bin) ready"
}

# ===========================================
# Prepare i.MX mkimage (correct modern way)
# ===========================================
prepare_mkimage() {
  log "Preparing i.MX mkimage environment..."

  local tools="$WORKDIR/$UBOOT_TOOLS_DIR"
  local uboot="$WORKDIR/uboot-imx"
  local mk="$tools/imx-mkimage"
  local imx8m="$mk/iMX8M"

  # Make sure we have the directories
  mkdir -p "$imx8m"

  # ---- required binaries from U-Boot ----
  local required=(
    "$uboot/u-boot.bin"
    "$uboot/u-boot-nodtb.bin"
    "$uboot/spl/u-boot-spl.bin"
    "$uboot/tools/mkimage"
  )

  for f in "${required[@]}"; do
    if [ ! -f "$f" ]; then
      echo "ERROR: Required file missing: $f"
      echo "       Rebuild U-Boot first (target 'uboot')"
      exit 1
    fi
  done

  # Copy binaries into iMX8M/
  cp -f "$uboot/u-boot.bin"            "$imx8m/"
  cp -f "$uboot/u-boot-nodtb.bin"      "$imx8m/"
  cp -f "$uboot/spl/u-boot-spl.bin"    "$imx8m/"
  cp -f "$uboot/tools/mkimage"         "$imx8m/mkimage_uboot"

  # DTBs
  for dtb in $DTBS; do
    local src="$uboot/arch/arm/dts/$dtb"
    if [ ! -f "$src" ]; then
      echo "ERROR: DTB not found: $src"
      exit 1
    fi
    cp -f "$src" "$imx8m/"
  done

  # ATF
  if [ ! -f "$tools/bl31.bin" ]; then
    echo "ERROR: bl31.bin not found in $tools"
    exit 1
  fi
  cp -f "$tools/bl31.bin" "$imx8m/"

  # DDR firmware (whatever was extracted)
  # Common names for i.MX8MP
  for f in "$tools"/lpddr4_pmu_train_*.bin \
           "$tools"/ddr4_*.bin \
           "$tools"/*dmem*.bin \
           "$tools"/*imem*.bin; do
    [ -f "$f" ] && cp -f "$f" "$imx8m/"
  done

  log "i.MX mkimage environment prepared (files are in $imx8m)"
}

# ===========================================
# Build Boot Image (correct modern way)
# ===========================================
build_image() {
  log "Building boot image..."

  local tools="$WORKDIR/$UBOOT_TOOLS_DIR"
  local mk="$tools/imx-mkimage"
  local imx8m="$mk/iMX8M"

  cd "$mk" || { echo "Cannot enter $mk"; exit 1; }

  # Clean previous build (top-level Makefile has the clean rule)
  make clean || true

  log "Running: make SOC=iMX8MP dtbs=\"$DTBS\" $UBOOT_TARGETS"
  make SOC=iMX8MP dtbs="$DTBS" $UBOOT_TARGETS

  local generated=""
  if [ -f "$imx8m/flash.bin" ]; then
    generated="$imx8m/flash.bin"
  elif [ -f "$imx8m/$OUTPUT_IMAGE" ]; then
    generated="$imx8m/$OUTPUT_IMAGE"
  else
    echo "ERROR: Boot image was not generated!"
    echo "Looked for flash.bin or $OUTPUT_IMAGE in $imx8m"
    ls -l "$imx8m"
    exit 1
  fi

  cp -f "$generated" "$tools/$OUTPUT_IMAGE"
  log "Boot image ready: $tools/$OUTPUT_IMAGE"
}


flash_image() {
  local img="$WORKDIR/$UBOOT_TOOLS_DIR/$OUTPUT_IMAGE"
  [ -f "$img" ] || { echo "No image at $img"; exit 1; }
  [ -b "$DEVICE" ] || { echo "$DEVICE is not a block device"; lsblk; exit 1; }

  echo "About to write $img → $DEVICE (offset 32 KiB)"
  read -rp "This will destroy data on $DEVICE. Continue? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || exit 0

  if $DRY_RUN; then
    echo "DRY-RUN: dd if=$img of=$DEVICE bs=1K seek=32 conv=fsync"
    return
  fi
  sudo dd if="$img" of="$DEVICE" bs=1K seek=32 conv=fsync status=progress
  sync
  log "Flashed successfully"
}

# ---------- main ----------
check_deps

case $BUILD_TARGET in
  prep)
    clone_or_update "$UBOOT_REPO" "$UBOOT_BRANCH" "$WORKDIR/uboot-imx"
    prepare_ddr
    build_atf
    ;;
  uboot)
    build_uboot
    ;;
  atf)
    build_atf
    ;;
  image)
    build_uboot
    prepare_ddr
    build_atf
    prepare_mkimage
    build_image
    ;;
  all)
    build_uboot
    prepare_ddr
    build_atf
    prepare_mkimage
    build_image
    log "Boot image ready. Flash the whole card with linux_imx_build.sh -f <device>"
    ;;
  flash)
    [ -n "$DEVICE" ] || { echo "ERROR: -d <device> required for flash"; exit 1; }
    flash_image
    ;;
  clean:*)
    target=${BUILD_TARGET#clean:}
    case $target in
      uboot) rm -rf "$WORKDIR/uboot-imx" ;;
      atf)   rm -rf "$WORKDIR/$UBOOT_TOOLS_DIR/imx-atf" ;;
      image) rm -rf "$WORKDIR/$UBOOT_TOOLS_DIR" ;;
      all)   rm -rf "$WORKDIR/uboot-imx" "$WORKDIR/$UBOOT_TOOLS_DIR" "$LOGFILE" ;;
      *)     echo "Unknown clean target: $target"; exit 1 ;;
    esac
    ;;
  *)
    usage
    ;;
esac
log "Done." 