#!/usr/bin/env bash

# Build a custom WSL2 kernel with zswap

set -e
set -o pipefail

sudo apt update
sudo apt install build-essential flex bison libssl-dev libelf-dev libncurses-dev autoconf libudev-dev libtool dwarves

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
    
    # Create temporary directory for modules installation
    if ! MODULES_TEMP=$(mktemp -d); then
        echo "Error: Failed to create temporary directory"
        exit 1
    fi
    
    # Save current directory
    BUILD_DIR=$(pwd)
    
    # Install modules to temporary directory
    if ! make modules_install INSTALL_MOD_PATH="${MODULES_TEMP}"; then
        echo "Error: Failed to install kernel modules"
        rm -rf "${MODULES_TEMP}"
        exit 1
    fi
    
    # Create tar.gz archive of modules directly in build directory
    cd "${MODULES_TEMP}"
    tar -czf "${BUILD_DIR}/modules.tar.gz" lib/
    cd "${BUILD_DIR}"
    
    # Cleanup
    rm -rf "${MODULES_TEMP}"
    
    cat << EOF

Kernel build complete for WSL2 kernel ${WSL2_KERNEL_VERSION}!

Next steps:
1. Copy "arch/x86/boot/bzImage" to "/mnt/c/bzImage"
2. Copy "modules.tar.gz" to "/mnt/c/modules.tar.gz"
3. Add the following to your ".wslconfig" file in your Windows user directory:

[wsl2]
kernel=C:\\\\bzImage

4. Extract the modules in your WSL2 instance:
   sudo tar -xzf /mnt/c/modules.tar.gz -C /

5. Restart your WSL2 instance:
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
