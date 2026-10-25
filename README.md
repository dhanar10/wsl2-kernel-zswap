# wsl2-kernel-zswap

WSL2 kernel with zswap.

Tested on:
- Ubuntu 22.04 with kernel 5.15.153.1-microsoft-standard-WSL2 (kernel 5.x)
- Ubuntu with kernel 6.x-microsoft-standard-WSL2 (kernel 6.x)

# Building

## Quick Start (review script first recommended)

```bash
# Download and review the script first
curl -O https://raw.githubusercontent.com/dhanar10/wsl2-kernel-zswap/main/build.sh
less build.sh

# After reviewing, run it
bash build.sh
```

## One-liner (use at your own risk)

```bash
curl https://raw.githubusercontent.com/dhanar10/wsl2-kernel-zswap/main/build.sh | bash
```

The script inspects the downloaded kernel's Kconfig definitions and enables only
the zswap options that kernel supports. This keeps older kernels that require
`CONFIG_FRONTSWAP`, `CONFIG_ZPOOL`, and `CONFIG_ZBUD` working while avoiding
removed options in newer kernels. It also enables
`CONFIG_ZSWAP_SHRINKER_DEFAULT_ON` when available. Kernel 6.x builds additionally
generate a `modules.vhdx` file containing kernel modules.

# Installation

## Kernel 5.x

After building, copy `arch/x86/boot/bzImage` to your Windows C: drive and configure `.wslconfig`:

```
[wsl2]
kernel=C:\\bzImage
```

Then restart WSL: `wsl --shutdown`

## Kernel 6.x

After building:

1. Copy `arch/x86/boot/bzImage` to `/mnt/c/bzImage`
2. Copy `modules.vhdx` to `/mnt/c/modules.vhdx`
3. Configure `.wslconfig` in your Windows user directory:
   ```
   [wsl2]
   kernel=C:\\bzImage
   kernelModules=C:\\modules.vhdx
   ```
4. Restart WSL: `wsl --shutdown`

# Verifying zswap

After restarting WSL, verify zswap is enabled:

```bash
cat /sys/module/zswap/parameters/enabled
# Should output: Y

cat /sys/module/zswap/parameters/compressor
# Should output: zstd
```
