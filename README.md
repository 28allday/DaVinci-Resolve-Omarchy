# DaVinci Resolve - Omarchy

Install [DaVinci Resolve](https://www.blackmagicdesign.com/products/davinciresolve) on [Omarchy](https://omarchy.com) (Arch Linux + Hyprland) with NVIDIA GPU support.

Handles all the compatibility quirks of running Resolve on Arch Linux — library conflicts, XWayland setup, RPATH patching, and legacy library shims — so you don't have to.

## Requirements

- **OS**: [Omarchy](https://omarchy.com) (Arch Linux)
- **GPU**: NVIDIA with proprietary drivers installed and working
- **Disk space**: ~10GB free in ~/Downloads for extraction (temporary)
- **DaVinci Resolve ZIP**: Downloaded from Blackmagic's website

## Quick Start

1. **Download DaVinci Resolve** from [blackmagicdesign.com](https://www.blackmagicdesign.com/products/davinciresolve)
   - Choose "DaVinci Resolve" (free) or "DaVinci Resolve Studio" (paid)
   - Select **Linux** and download the ZIP file
   - Save it to `~/Downloads/`

2. **Run the installer**:
```bash
git clone https://github.com/28allday/DaVinci-Resolve-Omarchy.git
cd DaVinci-Resolve-Omarchy
chmod +x Omarchy_resolve_v2.sh
./Omarchy_resolve_v2.sh
```

3. **Launch Resolve** from your app menu or run `resolve-nvidia-open`

## What It Does

### 1. Installs Dependencies

**Build/extraction tools:**

| Package | Purpose |
|---------|---------|
| `unzip` | Extracts the Resolve ZIP archive |
| `patchelf` | Modifies library search paths (RPATH) in binaries |
| `libarchive` | Archive handling library |
| `desktop-file-utils` | App menu integration |
| `file` | Identifies ELF binaries for RPATH patching |

**Runtime dependencies:**

| Package | Purpose |
|---------|---------|
| `libxcrypt-compat` | Provides legacy `libcrypt.so.1` (Arch dropped it) |
| `ffmpeg4.4` | Older FFmpeg version that Resolve links against |
| `glu` | OpenGL Utility Library for 3D rendering |
| `gtk2` | GTK2 toolkit (some Resolve UI components use it) |
| `fuse2` | AppImage compatibility layer |

### 2. Extracts Resolve

The download is a ZIP containing a `.run` file (self-extracting AppImage). The script unpacks it in stages:

```
ZIP → .run file → squashfs-root (actual application files)
```

Temporary files are cleaned up automatically when the script finishes.

### 3. Handles Library Conflicts (ABI-Safe)

This is the tricky part. Resolve bundles its own libraries, but some conflict with Arch's newer versions:

| Library | Action | Why |
|---------|--------|-----|
| `libglib-2.0.so` | **Replace** with system | Stable C ABI, safe to swap |
| `libgio-2.0.so` | **Replace** with system | Stable C ABI, safe to swap |
| `libgmodule-2.0.so` | **Replace** with system | Stable C ABI, safe to swap |
| `libc++.so` | **Keep** bundled | C++ ABI mismatch causes crashes |
| `libc++abi.so` | **Keep** bundled | C++ ABI mismatch causes crashes |

### 4. Patches RPATH

Every ELF binary in Resolve gets its RPATH patched to point to `/opt/resolve/libs/` and subdirectories. Without this, binaries would look for libraries in the original AppImage paths that no longer exist.

### 5. Creates XWayland Wrapper

Resolve doesn't support native Wayland. The wrapper script (`resolve-nvidia-open`) forces XWayland mode by setting `QT_QPA_PLATFORM=xcb`, and also clears stale Qt lockfiles that can prevent Resolve from starting after a crash.

### 6. Desktop Integration

- Installs `.desktop` files for the app menu
- Installs icons at proper hicolor sizes
- Installs udev rules for Blackmagic hardware (capture cards, control panels)
- Points all launchers at the XWayland wrapper

## Files Installed

### Application

| Path | Purpose |
|------|---------|
| `/opt/resolve/` | Main application directory |
| `/opt/resolve/bin/resolve` | Resolve binary |
| `/opt/resolve/libs/` | Bundled libraries |

### Scripts

| Path | Purpose |
|------|---------|
| `/usr/local/bin/resolve-nvidia-open` | XWayland wrapper (main launcher) |
| `/usr/bin/davinci-resolve` | Convenience symlink to wrapper |

### Desktop Entries

| Path | Purpose |
|------|---------|
| `/usr/share/applications/DaVinciResolve.desktop` | System app menu entry |
| `~/.local/share/applications/davinci-resolve-wrapper.desktop` | User entry (takes priority) |

### Icons

| Path | Purpose |
|------|---------|
| `/usr/share/icons/hicolor/128x128/apps/davinci-resolve.png` | App icon |

### Hardware Support

| Path | Purpose |
|------|---------|
| `/usr/lib/udev/rules.d/99-BlackmagicDevices.rules` | Blackmagic capture cards |
| `/usr/lib/udev/rules.d/99-ResolveKeyboardHID.rules` | Resolve Editor Keyboard |
| `/usr/lib/udev/rules.d/99-DavinciPanel.rules` | DaVinci control panels |

## Configuration

### Full System Upgrade

By default, the script syncs the package database without upgrading. To include a full system upgrade:

```bash
RESOLVE_FULL_UPGRADE=1 ./Omarchy_resolve_v2.sh
```

### Hybrid GPU Laptops (Optimus)

If you have an Intel iGPU + NVIDIA dGPU, edit the wrapper to force Resolve onto the NVIDIA GPU:

```bash
sudo nano /usr/local/bin/resolve-nvidia-open
```

Uncomment these lines:
```bash
export __NV_PRIME_RENDER_OFFLOAD=1
export __GLX_VENDOR_LIBRARY_NAME=nvidia
```

## Troubleshooting

### Resolve won't start / crashes immediately

- Check logs: `~/.local/share/DaVinciResolve/logs/ResolveDebug.txt`
- Verify NVIDIA driver is working: `nvidia-smi`
- Try launching from terminal to see errors: `resolve-nvidia-open`

### "Cannot open display" error

- Make sure XWayland is enabled in Hyprland (it is by default on Omarchy)
- Check the wrapper is using xcb: `grep QT_QPA_PLATFORM /usr/local/bin/resolve-nvidia-open`

### Resolve says "single instance already running"

Stale lockfiles from a previous crash. The wrapper clears these automatically, but if it persists:

```bash
rm -f /tmp/qtsingleapp-DaVinci*
```

### Missing library errors

Re-run the installer — it will re-patch RPATH and re-check dependencies:

```bash
./Omarchy_resolve_v2.sh
```

### GPU not detected / OpenCL errors

- Ensure NVIDIA drivers are installed: `pacman -Qi nvidia-utils`
- Check GPU is visible: `nvidia-smi`
- Verify OpenCL: `pacman -S --needed opencl-nvidia`

## Updating Resolve

1. Download the new version ZIP from Blackmagic's website to `~/Downloads/`
2. Run the installer again — it automatically picks the newest ZIP:

```bash
./Omarchy_resolve_v2.sh
```

The previous installation at `/opt/resolve` will be replaced.

## Uninstalling

```bash
# Remove application
sudo rm -rf /opt/resolve

# Remove scripts
sudo rm -f /usr/local/bin/resolve-nvidia-open
sudo rm -f /usr/bin/davinci-resolve

# Remove desktop entries
sudo rm -f /usr/share/applications/DaVinciResolve.desktop
sudo rm -f /usr/share/applications/DaVinciControlPanelsSetup.desktop
sudo rm -f /usr/share/applications/blackmagicraw-player.desktop
sudo rm -f /usr/share/applications/blackmagicraw-speedtest.desktop
rm -f ~/.local/share/applications/davinci-resolve-wrapper.desktop

# Remove icons
sudo rm -f /usr/share/icons/hicolor/128x128/apps/davinci-resolve.png
sudo rm -f /usr/share/icons/hicolor/128x128/apps/davinci-resolve-panels-setup.png
sudo rm -f /usr/share/icons/hicolor/256x256/apps/blackmagicraw-player.png
sudo rm -f /usr/share/icons/hicolor/256x256/apps/blackmagicraw-speedtest.png

# Remove udev rules
sudo rm -f /usr/lib/udev/rules.d/99-BlackmagicDevices.rules
sudo rm -f /usr/lib/udev/rules.d/99-ResolveKeyboardHID.rules
sudo rm -f /usr/lib/udev/rules.d/99-DavinciPanel.rules

# Remove user data (WARNING: deletes all projects and settings)
rm -rf ~/.local/share/DaVinciResolve

# Update caches
sudo update-desktop-database
sudo gtk-update-icon-cache -f /usr/share/icons/hicolor
```

## Credits

- [Omarchy](https://omarchy.com) - The Arch Linux distribution this was built for
- [Blackmagic Design](https://www.blackmagicdesign.com/) - DaVinci Resolve
- [Hyprland](https://hyprland.org/) - Wayland compositor (XWayland support)

## License

This project is provided as-is for the Omarchy community.
