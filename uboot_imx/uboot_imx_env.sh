#!/bin/bash
# U-Boot Environment Variables – fixed & cleaned

# Repositories
UBOOT_REPO="https://github.com/varigit/uboot-imx.git"
UBOOT_BRANCH="lf_v2023.04_var02"

ATF_REPO="https://github.com/varigit/imx-atf.git"
ATF_BRANCH="lf_v2.8_var03"

META_VARISCITE_BSP_REPO="https://github.com/varigit/meta-variscite-bsp.git"
META_VARISCITE_BSP_BRANCH="mickledore-var02"

IMX_MKIMAGE_REPO="https://github.com/nxp-imx/imx-mkimage.git"
IMX_MKIMAGE_BRANCH="lf-6.6.3_1.0.0"

# DDR firmware
DDR_FIRMWARE_BASE_URL="https://www.nxp.com/lgfiles/NMG/MAD/YOCTO/"
DDR_FIRMWARE_VERSION="8.18"
DDR_FIRMWARE_URL="${DDR_FIRMWARE_BASE_URL}firmware-imx-${DDR_FIRMWARE_VERSION}.bin"

# Cross compile
CROSS_COMPILE_ARM64="aarch64-linux-gnu-"
ARCH_ARM64="arm64"

# Optional: enable ccache if present
if command -v ccache &>/dev/null; then
  CROSS_COMPILE_ARM64="ccache ${CROSS_COMPILE_ARM64}"
  ccache --max-size=20G
fi

LOGFILE="./uboot_build.log"

# Board specific
UBOOT_DTB_NAME="imx8mp-var-dart-dt8mcustomboard.dtb"
UBOOT_DTB_EXTRA="imx8mp-var-som-symphony.dtb"
DTBS="${UBOOT_DTB_NAME} ${UBOOT_DTB_EXTRA}"

UBOOT_TOOLS_DIR="imx-boot-tools"
UBOOT_SOC_TARGET="iMX8MP"
UBOOT_TARGETS="flash_evk"
OUTPUT_IMAGE="imx-boot-sd.bin"
UBOOT_DEFCONFIG="imx8mp_var_dart_defconfig"