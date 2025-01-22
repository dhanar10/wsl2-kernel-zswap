#!/usr/bin/env bash

# Build a custom WSL2 kernel with zwap

set -e
set -o pipefail

sudo apt update
sudo apt install build-essential flex bison libssl-dev libelf-dev libncurses-dev autoconf libudev-dev libtool dwarves

WSL2_KERNEL_VERSION="$(uname -r | grep -o '^[0-9\.]\+')"

wget -c https://github.com/microsoft/WSL2-Linux-Kernel/archive/refs/tags/linux-msft-wsl-${WSL2_KERNEL_VERSION}.tar.gz
tar xvf linux-msft-wsl-${WSL2_KERNEL_VERSION}.tar.gz

cd "WSL2-Linux-Kernel-linux-msft-wsl-${WSL2_KERNEL_VERSION}"

cp Microsoft/config-wsl .config           # Use WSL default kernel config as the base
cat << EOF >> .config

CONFIG_FRONTSWAP=y
CONFIG_ZSWAP=y
CONFIG_ZSWAP_COMPRESSOR_DEFAULT_LZO=y
CONFIG_ZSWAP_COMPRESSOR_DEFAULT="lzo"
CONFIG_ZSWAP_ZPOOL_DEFAULT_ZBUD=y
CONFIG_ZSWAP_ZPOOL_DEFAULT="zbud"
CONFIG_ZSWAP_DEFAULT_ON=y
CONFIG_ZPOOL=y
CONFIG_ZBUD=y
CONFIG_CRYPTO_LZO=y
EOF
make olddefconfig

make -j $(nproc)

cat << EOF

Next, copy "arch/x86/boot/bzImage" to "/mnt/c" and 
add the following to your ".wslconfig".

[wsl2]
kernel=C:\\\\bzImage

After that, restart your WSL2 instance by executing 
"wsl --shutdown" and then reopening your WSL2 terminal.
EOF
