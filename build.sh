#!/usr/bin/env bash

# Build a custom WSL2 kernel with zswap

set -e
set -o pipefail

sudo apt update
sudo apt install build-essential flex bison libssl-dev libelf-dev libncurses-dev autoconf libudev-dev libtool dwarves

WSL2_KERNEL_VERSION="$(uname -r | grep -o '^[0-9\.]\+')"
KERNEL_MAJOR_VERSION="$(echo ${WSL2_KERNEL_VERSION} | cut -d. -f1)"

wget -c https://github.com/microsoft/WSL2-Linux-Kernel/archive/refs/tags/linux-msft-wsl-${WSL2_KERNEL_VERSION}.tar.gz
tar xvf linux-msft-wsl-${WSL2_KERNEL_VERSION}.tar.gz

cd "WSL2-Linux-Kernel-linux-msft-wsl-${WSL2_KERNEL_VERSION}"

cp Microsoft/config-wsl .config           # Use WSL default kernel config as the base

# Add zswap configuration based on kernel version
if [ "$KERNEL_MAJOR_VERSION" -lt 6 ]; then
    # Kernel 5.x configuration with CONFIG_FRONTSWAP
    cat << EOF >> .config

CONFIG_CRYPTO_ZSTD=y
CONFIG_ZSTD_COMMON=y
CONFIG_ZSTD_COMPRESS=y

CONFIG_FRONTSWAP=y
CONFIG_ZSWAP=y
CONFIG_ZSWAP_COMPRESSOR_DEFAULT_ZSTD=y
CONFIG_ZSWAP_COMPRESSOR_DEFAULT="zstd"
CONFIG_ZSWAP_ZPOOL_DEFAULT_ZBUD=y
CONFIG_ZSWAP_ZPOOL_DEFAULT="zbud"
CONFIG_ZSWAP_DEFAULT_ON=y
CONFIG_ZPOOL=y
CONFIG_ZBUD=y
EOF
else
    # Kernel 6.x configuration (CONFIG_FRONTSWAP removed)
    cat << EOF >> .config

CONFIG_CRYPTO_ZSTD=y
CONFIG_ZSTD_COMMON=y
CONFIG_ZSTD_COMPRESS=y

CONFIG_ZSWAP=y
CONFIG_ZSWAP_COMPRESSOR_DEFAULT_ZSTD=y
CONFIG_ZSWAP_COMPRESSOR_DEFAULT="zstd"
CONFIG_ZSWAP_ZPOOL_DEFAULT_ZBUD=y
CONFIG_ZSWAP_ZPOOL_DEFAULT="zbud"
CONFIG_ZSWAP_DEFAULT_ON=y
CONFIG_ZPOOL=y
CONFIG_ZBUD=y
EOF
fi

make olddefconfig

make -j $(nproc)

# For kernel 6.x, also build and package modules
if [ "$KERNEL_MAJOR_VERSION" -ge 6 ]; then
    echo "Building and packaging kernel modules for WSL2 kernel 6.x..."
    
    # Create temporary directory for modules installation
    MODULES_TEMP=$(mktemp -d)
    
    # Install modules to temporary directory
    make modules_install INSTALL_MOD_PATH="${MODULES_TEMP}"
    
    # Create tar.gz archive of modules
    cd "${MODULES_TEMP}"
    tar -czf ../modules.tar.gz lib/
    cd -
    
    # Move modules archive to a convenient location
    mv "${MODULES_TEMP}/../modules.tar.gz" ./modules.tar.gz
    
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
