#!/usr/bin/env bash

# Build a custom WSL2 kernel with zswap

set -e
set -o pipefail

sudo apt update
sudo apt install build-essential flex bison libssl-dev libelf-dev libncurses-dev autoconf libudev-dev libtool dwarves cpio qemu-utils

WSL2_KERNEL_VERSION="$(uname -r | grep -o '^[0-9\.]\+')"
KERNEL_MAJOR_VERSION="$(echo "${WSL2_KERNEL_VERSION}" | cut -d. -f1)"

# Validate kernel version was extracted correctly
if [ -z "${KERNEL_MAJOR_VERSION}" ] || ! [[ "${KERNEL_MAJOR_VERSION}" =~ ^[0-9]+$ ]]; then
    echo "Error: Could not determine kernel major version from: $(uname -r)"
    echo "Expected format: X.Y.Z.W (e.g., 5.15.153.1 or 6.6.36.3)"
    exit 1
fi

echo "Detected WSL2 kernel version: ${WSL2_KERNEL_VERSION} (major: ${KERNEL_MAJOR_VERSION})"

wget -c https://github.com/microsoft/WSL2-Linux-Kernel/archive/refs/tags/linux-msft-wsl-${WSL2_KERNEL_VERSION}.tar.gz
tar xvf linux-msft-wsl-${WSL2_KERNEL_VERSION}.tar.gz

cd "WSL2-Linux-Kernel-linux-msft-wsl-${WSL2_KERNEL_VERSION}"

cp Microsoft/config-wsl .config           # Use WSL default kernel config as the base

# Add zswap configuration
# Common configuration for all kernel versions
cat << EOF >> .config

CONFIG_CRYPTO_ZSTD=y
CONFIG_ZSTD_COMMON=y
CONFIG_ZSTD_COMPRESS=y

EOF

# Add CONFIG_FRONTSWAP for kernel 5.x only (removed in 6.x)
if [ "$KERNEL_MAJOR_VERSION" -lt 6 ]; then
    cat << EOF >> .config
CONFIG_FRONTSWAP=y
EOF
fi

# Add remaining zswap configuration (common to all versions)
cat << EOF >> .config
CONFIG_ZSWAP=y
CONFIG_ZSWAP_COMPRESSOR_DEFAULT_ZSTD=y
CONFIG_ZSWAP_COMPRESSOR_DEFAULT="zstd"
CONFIG_ZSWAP_ZPOOL_DEFAULT_ZBUD=y
CONFIG_ZSWAP_ZPOOL_DEFAULT="zbud"
CONFIG_ZSWAP_DEFAULT_ON=y
CONFIG_ZPOOL=y
CONFIG_ZBUD=y
EOF

make olddefconfig

make -j $(nproc)

# For kernel 6.x, also build and package modules
if [ "$KERNEL_MAJOR_VERSION" -ge 6 ]; then
    echo "Building and packaging kernel modules for WSL2 kernel 6.x..."
    
    # Save current directory
    BUILD_DIR=$(pwd)
    
    # Install modules to a modules directory
    if ! make modules_install INSTALL_MOD_PATH="${BUILD_DIR}/modules"; then
        echo "Error: Failed to install kernel modules"
        exit 1
    fi
    
    # Get kernel release version
    KERNEL_RELEASE=$(make -s kernelrelease)
    
    # Create VHDX containing the modules
    echo "Creating modules VHDX..."
    
    # Calculate modules size (+ 256MiB for slack)
    MODULES_SIZE=$(du -bs "${BUILD_DIR}/modules" | awk '{print $1;}')
    MODULES_SIZE=$((MODULES_SIZE + (256*(1<<20))))
    
    # Create temporary directory for VHDX creation
    if ! TMP_DIR=$(mktemp -d); then
        echo "Error: Failed to create temporary directory"
        exit 1
    fi
    
    # Create a blank image file
    dd if=/dev/zero of="${TMP_DIR}/modules.img" bs=1024 count=$((MODULES_SIZE / 1024)) status=progress
    
    # Set up filesystem and mount
    LO_DEV=$(sudo losetup --find --show "${TMP_DIR}/modules.img")
    sudo mkfs -t ext4 "${LO_DEV}"
    mkdir "${TMP_DIR}/modules_img"
    sudo mount "${LO_DEV}" "${TMP_DIR}/modules_img"
    sudo chmod a+rw "${TMP_DIR}/modules_img"
    
    # Copy over the modules
    sudo cp -r "${BUILD_DIR}/modules/lib/modules/${KERNEL_RELEASE}"/* "${TMP_DIR}/modules_img"
    sudo umount "${TMP_DIR}/modules_img"
    sudo losetup -d "${LO_DEV}"
    
    # Convert to VHDX
    qemu-img convert -O vhdx "${TMP_DIR}/modules.img" "${BUILD_DIR}/modules.vhdx"
    
    # Cleanup temporary files
    rm -rf "${TMP_DIR}"
    rm -rf "${BUILD_DIR}/modules"
    
    cat << EOF

Kernel build complete for WSL2 kernel ${WSL2_KERNEL_VERSION}!

Next steps:
1. Copy "arch/x86/boot/bzImage" to "/mnt/c/bzImage"
2. Copy "modules.vhdx" to "/mnt/c/modules.vhdx"
3. Add the following to your ".wslconfig" file in your Windows user directory:

[wsl2]
kernel=C:\\\\bzImage
kernelModules=C:\\\\modules.vhdx

4. Restart your WSL2 instance:
   wsl --shutdown
   
Then reopen your WSL2 terminal. The new kernel with zswap support will be active.
EOF
else
    cat << EOF

Kernel build complete for WSL2 kernel ${WSL2_KERNEL_VERSION}!

Next steps:
1. Copy "arch/x86/boot/bzImage" to "/mnt/c/bzImage"
2. Add the following to your ".wslconfig" file in your Windows user directory:

[wsl2]
kernel=C:\\\\bzImage

3. Restart your WSL2 instance:
   wsl --shutdown

Then reopen your WSL2 terminal. The new kernel with zswap support will be active.
EOF
fi
