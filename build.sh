#!/usr/bin/env bash

# Build a custom WSL2 kernel with zswap

set -e
set -o pipefail

sudo apt update
sudo apt install build-essential flex bison libssl-dev libelf-dev libncurses-dev autoconf libudev-dev libtool dwarves cpio qemu-utils pkg-config python3 python-is-python3 python3-dev

WSL2_KERNEL_VERSION="$(uname -r | grep -o '^[0-9\.]\+')"
KERNEL_MAJOR_VERSION="$(echo "${WSL2_KERNEL_VERSION}" | cut -d. -f1)"

# Validate kernel version was extracted correctly
if [[ -z "${KERNEL_MAJOR_VERSION}" ]] || ! [[ "${KERNEL_MAJOR_VERSION}" =~ ^[0-9]+$ ]]; then
  echo "Error: Could not determine kernel major version from: $(uname -r)"
  echo "Expected format: X.Y.Z.W (e.g., 5.15.153.1 or 6.6.36.3)"
  exit 1
fi

echo "Detected WSL2 kernel version: ${WSL2_KERNEL_VERSION} (major: ${KERNEL_MAJOR_VERSION})"

wget -c https://github.com/microsoft/WSL2-Linux-Kernel/archive/refs/tags/linux-msft-wsl-${WSL2_KERNEL_VERSION}.tar.gz
tar xvf linux-msft-wsl-${WSL2_KERNEL_VERSION}.tar.gz

cd "WSL2-Linux-Kernel-linux-msft-wsl-${WSL2_KERNEL_VERSION}"

cp Microsoft/config-wsl .config           # Use WSL default kernel config as the base

# Kconfig symbols have changed independently of the kernel major version. For
# example, older kernels require FRONTSWAP/ZPOOL/ZBUD, while newer kernels
# select their allocator directly. Only request options declared by this tree.
kconfig_symbol_supported() {
  local symbol="$1"

  grep -Rqs --include='Kconfig*' \
    -E "^[[:space:]]*(menu)?config[[:space:]]+${symbol}([[:space:]]|$)" .
}

enable_if_supported() {
  local symbol="$1"

  if kconfig_symbol_supported "${symbol}"; then
    ./scripts/config --enable "${symbol}"
    echo "Enabled CONFIG_${symbol}"
  else
    echo "Skipping unsupported CONFIG_${symbol}"
  fi
}

select_choice_if_supported() {
  local choice_prefix="$1"
  local selected_symbol="$2"
  local symbol

  if ! kconfig_symbol_supported "${selected_symbol}"; then
    echo "Skipping unsupported CONFIG_${selected_symbol}; keeping the kernel default"
    return
  fi

  # Disable every supported alternative first so olddefconfig cannot retain a
  # competing selection from Microsoft/config-wsl.
  while read -r symbol; do
    [[ -n "${symbol}" ]] || continue
    ./scripts/config --disable "${symbol}"
  done < <(
    grep -Rh --include='Kconfig*' \
      -E "^[[:space:]]*config[[:space:]]+${choice_prefix}[A-Z0-9_]+([[:space:]]|$)" . |
      sed -E 's/^[[:space:]]*config[[:space:]]+([A-Z0-9_]+).*/\1/' |
      sort -u
  )

  ./scripts/config --enable "${selected_symbol}"
  echo "Selected CONFIG_${selected_symbol}"
}

generate_modules_vhdx() (
  local modules_dir="$1"
  local kernel_release="$2"
  local output="$3"
  local module_tree="${modules_dir}/lib/modules/${kernel_release}"
  local temp_dir
  local modules_size
  local image_size

  if [[ ! -d "${module_tree}" ]]; then
    echo "Error: Could not find installed modules at ${module_tree}" >&2
    return 1
  fi

  if [[ -e "${output}" ]]; then
    echo "Error: Refusing to overwrite existing file ${output}" >&2
    return 1
  fi

  modules_size=$(du -sb -- "${module_tree}" | awk '{print $1}')
  image_size=$(( ((modules_size + 256 * 1024 * 1024 + 1048575) / 1048576) * 1048576 ))
  temp_dir=$(mktemp -d)
  trap 'rm -rf -- "${temp_dir}"' EXIT

  truncate -s "${image_size}" "${temp_dir}/modules.img"
  if ! mkfs.ext4 -F -d "${module_tree}" "${temp_dir}/modules.img"; then
    echo "Error: Failed to create ext4 filesystem for kernel modules" >&2
    return 1
  fi
  if ! qemu-img convert -O vhdx "${temp_dir}/modules.img" "${output}"; then
    echo "Error: Failed to convert kernel modules image to VHDX" >&2
    return 1
  fi
)

enable_if_supported CRYPTO_ZSTD
enable_if_supported ZSTD_COMMON
enable_if_supported ZSTD_COMPRESS
enable_if_supported FRONTSWAP
enable_if_supported ZSWAP
select_choice_if_supported ZSWAP_COMPRESSOR_DEFAULT_ ZSWAP_COMPRESSOR_DEFAULT_ZSTD
select_choice_if_supported ZSWAP_ZPOOL_DEFAULT_ ZSWAP_ZPOOL_DEFAULT_ZBUD
enable_if_supported ZSWAP_DEFAULT_ON
enable_if_supported ZSWAP_SHRINKER_DEFAULT_ON
enable_if_supported ZPOOL
enable_if_supported ZBUD

make olddefconfig

# Fail early if Kconfig could not satisfy the essential zswap settings. The
# shrinker is checked only when this kernel exposes the option.
if ! grep -qx 'CONFIG_ZSWAP=y' .config; then
  echo "Error: CONFIG_ZSWAP could not be enabled for this kernel configuration"
  exit 1
fi

if ! grep -qx 'CONFIG_ZSWAP_DEFAULT_ON=y' .config; then
  echo "Error: CONFIG_ZSWAP_DEFAULT_ON could not be enabled"
  exit 1
fi

if kconfig_symbol_supported ZSWAP_SHRINKER_DEFAULT_ON && \
    ! grep -qx 'CONFIG_ZSWAP_SHRINKER_DEFAULT_ON=y' .config; then
  echo "Error: CONFIG_ZSWAP_SHRINKER_DEFAULT_ON is supported but could not be enabled"
  exit 1
fi

make -j $(nproc)

# For kernel 6.x, also build and package modules
if [[ "${KERNEL_MAJOR_VERSION}" -ge 6 ]]; then
  echo "Building and packaging kernel modules for WSL2 kernel 6.x..."

  # Save current directory
  BUILD_DIR=$(pwd)

  # Set up cleanup trap to ensure modules directory is removed on error
  cleanup_modules() {
    if [[ -d "${BUILD_DIR}/modules" ]]; then
      rm -rf "${BUILD_DIR}/modules"
    fi
  }
  trap cleanup_modules EXIT

  # Install modules to a modules directory
  if ! make modules_install INSTALL_MOD_PATH="${BUILD_DIR}/modules"; then
    echo "Error: Failed to install kernel modules"
    exit 1
  fi

  # Get kernel release version
  KERNEL_RELEASE=$(make -s kernelrelease)
  
  # Validate kernel release was extracted correctly
  if [[ -z "${KERNEL_RELEASE}" ]]; then
    echo "Error: Could not determine kernel release version"
    exit 1
  fi

  # The generator was renamed; support both names across kernel releases.
  VHDX_SCRIPT="./Microsoft/scripts/gen_artifacts_vhdx.sh"
  if [[ ! -f "${VHDX_SCRIPT}" ]]; then
    VHDX_SCRIPT="./Microsoft/scripts/gen_modules_vhdx.sh"
  fi

  if [[ -f "${VHDX_SCRIPT}" ]] && [[ "${VHDX_SCRIPT}" == "./Microsoft/scripts/gen_artifacts_vhdx.sh" ]]; then
    if ! make headers_install INSTALL_HDR_PATH="${BUILD_DIR}/headers"; then
      echo "Error: Failed to install kernel headers"
      exit 1
    fi

    if ! make -C tools/perf NO_JEVENTS=1 NO_JVMTI=1 NO_LIBTRACEEVENT=1 \
        install DESTDIR="${BUILD_DIR}/perf" prefix=/; then
      echo "Error: Failed to build and install perf"
      exit 1
    fi

    VHDX_ARGS=(
      "${BUILD_DIR}/modules"
      "${BUILD_DIR}/headers"
      "${BUILD_DIR}/perf"
      "${KERNEL_RELEASE}"
      "${BUILD_DIR}/modules.vhdx"
    )
  elif [[ -f "${VHDX_SCRIPT}" ]]; then
    VHDX_ARGS=(
      "${BUILD_DIR}/modules"
      "${KERNEL_RELEASE}"
      "${BUILD_DIR}/modules.vhdx"
    )
  fi

  if [[ -f "${VHDX_SCRIPT}" ]]; then
    echo "Creating modules VHDX using ${VHDX_SCRIPT}..."
    if ! sudo "${VHDX_SCRIPT}" "${VHDX_ARGS[@]}"; then
      echo "Error: Failed to create modules VHDX"
      exit 1
    fi
  else
    echo "Microsoft's VHDX generator was not found; using the built-in fallback..."
    if ! generate_modules_vhdx "${BUILD_DIR}/modules" "${KERNEL_RELEASE}" "${BUILD_DIR}/modules.vhdx"; then
      echo "Error: Failed to create modules VHDX"
      exit 1
    fi
  fi

  # Cleanup modules directory and remove trap
  trap - EXIT
  cleanup_modules

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
