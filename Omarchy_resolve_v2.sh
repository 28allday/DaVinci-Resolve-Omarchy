#!/usr/bin/env bash
# ==============================================================================
# DaVinci Resolve Installer for Omarchy (Arch Linux + Hyprland + NVIDIA)
#
# DaVinci Resolve is a professional video editing suite by Blackmagic Design.
# It's distributed as a self-extracting AppImage-style .run file inside a ZIP.
# This script automates the entire installation process on Omarchy, handling
# all the quirks and workarounds needed to get Resolve running on Arch Linux.
#
# Why this script exists:
#   Resolve is built for CentOS/RHEL and bundles its own versions of many
#   libraries. On Arch Linux, some of these bundled libraries conflict with
#   system libraries (especially glib), while others (libc++, libc++abi)
#   MUST be kept because Resolve was compiled against specific ABI versions.
#   Getting this balance right is tricky — this script handles it automatically.
#
# What this script does:
#   1. Finds the Resolve ZIP in ~/Downloads/
#   2. Installs system dependencies (codecs, GPU libs, legacy compat libs)
#   3. Extracts the ZIP → .run → squashfs-root (AppImage payload)
#   4. Replaces bundled glib/gio/gmodule with system versions (ABI-safe)
#   5. Keeps vendor libc++/libc++abi (removing these breaks Resolve)
#   6. Installs to /opt/resolve with RPATH patching for all ELF binaries
#   7. Ensures legacy libcrypt.so.1 is available (Arch dropped it)
#   8. Installs desktop entries, icons, and udev rules
#   9. Creates an XWayland wrapper script for Hyprland compatibility
#
# Prerequisites:
#   - Omarchy (Arch Linux) with NVIDIA drivers installed and working
#   - DaVinci Resolve Linux ZIP downloaded to ~/Downloads/
#   - Internet connection (for installing packages)
# ==============================================================================

set -euo pipefail

# Logging helpers with visual indicators for easy scanning of output
log(){ echo -e "▶ $*"; }
warn(){ echo -e "⚠️  $*" >&2; }
err(){ echo -e "❌ $*" >&2; exit 1; }

# Find the Resolve ZIP file in ~/Downloads/. The user must download it
# manually from https://www.blackmagicdesign.com/products/davinciresolve
# because Blackmagic requires filling out a form (no direct download link).
# If multiple ZIPs exist (e.g. different versions), we use the newest one.
ZIP_DIR="${HOME}/Downloads"
shopt -s nullglob
ZIP_FILES=("${ZIP_DIR}"/DaVinci_Resolve*_Linux.zip)
shopt -u nullglob
if [[ ${#ZIP_FILES[@]} -eq 0 ]]; then
  err "Put the official DaVinci Resolve Linux ZIP in ${ZIP_DIR}"
fi
# Sort by modification time, newest first
RESOLVE_ZIP="$(ls -1t "${ZIP_FILES[@]}" 2>/dev/null | head -n1)"
[[ -n "${RESOLVE_ZIP}" ]] || err "Could not determine newest ZIP file"
log "Using installer ZIP: ${RESOLVE_ZIP}"

# ==================== Package Installation ====================
#
# System upgrade is opt-in because a full -Syu can update the kernel or
# NVIDIA driver stack, which might break things or require a reboot in
# the middle of the install. Set RESOLVE_FULL_UPGRADE=1 if you want it.
# Otherwise we just sync the package database (-Sy) so pacman knows
# what's available without actually upgrading anything.
if [[ "${RESOLVE_FULL_UPGRADE:-0}" == "1" ]]; then
  log "Updating system packages (RESOLVE_FULL_UPGRADE=1)..."
  sudo pacman -Syu --noconfirm
else
  log "Skipping full system upgrade (set RESOLVE_FULL_UPGRADE=1 to enable)"
  # Just sync package database without upgrading
  sudo pacman -Sy --noconfirm
fi
# Build/extraction tools:
#   unzip:              Extracts the Resolve ZIP archive
#   patchelf:           Modifies RPATH in ELF binaries (tells them where to find libs)
#   libarchive:         Archive handling library (dependency for extraction)
#   xdg-user-dirs:      Ensures standard user directories exist (~/Downloads, etc.)
#   desktop-file-utils: Provides update-desktop-database for app menu integration
#   file:               Identifies file types (used to find ELF binaries for patching)
#   gtk-update-icon-cache: Refreshes the icon cache so Resolve's icon appears
log "Installing required tools..."
if ! sudo pacman -S --needed --noconfirm unzip patchelf libarchive xdg-user-dirs desktop-file-utils file gtk-update-icon-cache; then
  warn "Some optional tools failed to install, continuing anyway..."
fi

# Runtime dependencies that Resolve needs but doesn't bundle:
#   libxcrypt-compat:   Provides legacy libcrypt.so.1 (Arch moved to libxcrypt v2)
#   ffmpeg4.4:          Older FFmpeg version that Resolve links against
#   glu:                OpenGL Utility Library (3D rendering support)
#   gtk2:               GTK2 toolkit (Resolve's UI uses some GTK2 components)
#   fuse2:              Filesystem in Userspace v2 (for AppImage compatibility)
#
# IMPORTANT: We deliberately do NOT replace Resolve's bundled libc++/libc++abi
# with system versions. Resolve was compiled against specific C++ ABI versions
# and swapping them causes crashes. Only glib/gio/gmodule get replaced (later).
log "Installing runtime dependencies..."
if ! sudo pacman -S --needed --noconfirm libxcrypt-compat ffmpeg4.4 glu gtk2 fuse2; then
  warn "Some runtime dependencies failed to install (may affect functionality)"
fi

# Resolve's built-in extras downloader expects TLS certificates at the
# Red Hat/CentOS path (/etc/pki/tls) rather than the Arch path (/etc/ssl).
# This symlink lets it find the system certificates.
if [[ ! -e /etc/pki/tls ]]; then
  sudo mkdir -p /etc/pki
  sudo ln -sf /etc/ssl /etc/pki/tls
fi

# ==================== Extraction ====================
#
# The Resolve download is a ZIP containing a .run file. The .run file is a
# self-extracting AppImage-style archive containing a squashfs filesystem.
# We extract it in stages: ZIP → .run → squashfs-root (the actual app files).
#
# This needs about 10GB of free space for the temporary extraction.
# Everything is cleaned up automatically when the script exits (via trap).
NEEDED_GB=10
FREE_KB=$(df --output=avail -k "${ZIP_DIR}" | tail -n1); FREE_GB=$((FREE_KB/1024/1024))
(( FREE_GB >= NEEDED_GB )) || err "Not enough free space in ${ZIP_DIR}: ${FREE_GB} GiB < ${NEEDED_GB} GiB"

# Create a temporary directory for extraction. Using mktemp ensures a unique
# name so multiple runs don't conflict. The cleanup trap removes it when the
# script exits (whether it succeeds, fails, or is interrupted with Ctrl+C).
WORKDIR="$(mktemp -d -p "${ZIP_DIR}" .resolve-extract-XXXXXXXX)"
cleanup() {
  if [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]]; then
    log "Cleaning up temporary directory..."
    rm -rf "${WORKDIR}" 2>/dev/null || true
  fi
}
trap cleanup EXIT
log "Unpacking ZIP to ${WORKDIR}…"
unzip -q "${RESOLVE_ZIP}" -d "${WORKDIR}"

# Find the .run installer inside the extracted ZIP. It's a self-extracting
# archive that contains the actual application files in a squashfs image.
# --appimage-extract tells it to just extract without trying to run anything.
RUN_FILE="$(find "${WORKDIR}" -maxdepth 2 -type f -name 'DaVinci_Resolve_*_Linux.run' | head -n1 || true)"
[[ -n "${RUN_FILE}" ]] || err "Could not find the .run installer in the ZIP"
chmod +x "${RUN_FILE}"

EX_DIR="$(dirname "${RUN_FILE}")"
log "Extracting AppImage payload…"
if ! ( cd "${EX_DIR}" && "./$(basename "${RUN_FILE}")" --appimage-extract >/dev/null ); then
  err "Failed to extract AppImage payload"
fi
APPDIR="${EX_DIR}/squashfs-root"
[[ -d "${APPDIR}" ]] || err "Extraction failed (no squashfs-root)"

# Normalize perms
chmod -R u+rwX,go+rX,go-w "${APPDIR}" || warn "Could not normalize all permissions"

# Minimal validation
[[ -s "${APPDIR}/bin/resolve" ]] || err "resolve binary missing or zero-size"

# ==================== ABI-Safe Library Replacement ====================
#
# This is the most delicate part of the install. Resolve bundles its own
# copies of many libraries, but some of them are too old for Arch and cause
# crashes or segfaults. The trick is knowing WHICH ones to replace:
#
# REPLACE with system versions (these are safe to swap):
#   - libglib-2.0.so.0    — GLib core library
#   - libgio-2.0.so.0     — GLib I/O library
#   - libgmodule-2.0.so.0 — GLib module loading
#   These are stable C libraries with a very consistent ABI.
#
# KEEP bundled versions (replacing these breaks Resolve):
#   - libc++.so           — C++ standard library (LLVM)
#   - libc++abi.so         — C++ ABI support library
#   Resolve was compiled with a specific libc++ version. Using the system
#   version causes ABI mismatches and immediate crashes.
pushd "${APPDIR}" >/dev/null

# Verify system libraries exist before replacing bundled ones
declare -A GLIB_LIBS=(
  ["/usr/lib/libglib-2.0.so.0"]="libs/libglib-2.0.so.0"
  ["/usr/lib/libgio-2.0.so.0"]="libs/libgio-2.0.so.0"
  ["/usr/lib/libgmodule-2.0.so.0"]="libs/libgmodule-2.0.so.0"
)
for syslib in "${!GLIB_LIBS[@]}"; do
  target="${GLIB_LIBS[$syslib]}"
  if [[ -e "${syslib}" ]]; then
    rm -f "${target}" || true
    ln -sf "${syslib}" "${target}" || warn "Failed to symlink ${syslib}"
  else
    warn "System library ${syslib} not found, keeping bundled version"
  fi
done

# Extract DaVinci control panel libraries from a bundled tarball and move
# them into the main libs/ directory so they're found at runtime. These
# support Blackmagic's hardware control surfaces (DaVinci Resolve Editor
# Keyboard, Mini Panel, Micro Panel, etc.).
if [[ -d "share/panels" ]]; then
  pushd "share/panels" >/dev/null
  tar -zxf dvpanel-framework-linux-x86_64.tgz 2>/dev/null || true
  mkdir -p "${APPDIR}/libs"
  find . -maxdepth 1 -type f -name '*.so' -exec mv -f {} "${APPDIR}/libs" \; 2>/dev/null || true
  if [[ -d lib ]]; then
    find lib -type f -name '*.so*' -exec mv -f {} "${APPDIR}/libs" \; 2>/dev/null || true
  fi
  popd >/dev/null
fi

# Clean up AppImage launcher files and installer leftovers — we don't need
# them since we're installing to /opt/resolve directly, not running as an AppImage.
rm -f "AppRun" "AppRun*" 2>/dev/null || true
rm -rf "installer" "installer*" 2>/dev/null || true
mkdir -p "bin"
ln -sf "../BlackmagicRAWPlayer/BlackmagicRawAPI" "bin/" 2>/dev/null || true
popd >/dev/null

# ==================== Install to /opt/resolve ====================
#
# Copy the extracted application to its final location. /opt/ is the
# standard Linux directory for third-party software that doesn't come
# from the package manager. Using rsync (if available) is faster for
# re-installs because it only copies changed files.
log "Installing Resolve to /opt/resolve…"
sudo rm -rf /opt/resolve
sudo mkdir -p /opt/resolve
if command -v rsync >/dev/null 2>&1; then
  sudo rsync -a --delete "${APPDIR}/" /opt/resolve/
else
  sudo cp -a "${APPDIR}/." /opt/resolve/
fi
sudo mkdir -p /opt/resolve/.license

# RPATH Patching
#
# RPATH is a field inside ELF binaries that tells the dynamic linker where
# to search for shared libraries. Resolve's binaries have RPATHs pointing
# to the original AppImage extraction paths, which don't exist anymore.
#
# We patch EVERY ELF binary (executables and shared objects) to search
# /opt/resolve/libs/ and all its subdirectories. This includes large files
# like libQt5WebEngineCore.so (~200MB) — skipping them causes "library not
# found" errors because they link to other Resolve libs.
#
# This step can take a minute or two due to the number of files.
log "Applying RPATH with patchelf (this may take a while for large libraries)…"
RPATH_DIRS=( "libs" "libs/plugins/sqldrivers" "libs/plugins/xcbglintegrations" "libs/plugins/imageformats"
             "libs/plugins/platforms" "libs/Fusion" "plugins" "bin"
             "BlackmagicRAWSpeedTest/BlackmagicRawAPI" "BlackmagicRAWSpeedTest/plugins/platforms"
             "BlackmagicRAWSpeedTest/plugins/imageformats" "BlackmagicRAWSpeedTest/plugins/mediaservice"
             "BlackmagicRAWSpeedTest/plugins/audio" "BlackmagicRAWSpeedTest/plugins/xcbglintegrations"
             "BlackmagicRAWSpeedTest/plugins/bearer"
             "BlackmagicRAWPlayer/BlackmagicRawAPI" "BlackmagicRAWPlayer/plugins/mediaservice"
             "BlackmagicRAWPlayer/plugins/imageformats" "BlackmagicRAWPlayer/plugins/audio"
             "BlackmagicRAWPlayer/plugins/platforms" "BlackmagicRAWPlayer/plugins/xcbglintegrations"
             "BlackmagicRAWPlayer/plugins/bearer"
             "Onboarding/plugins/xcbglintegrations" "Onboarding/plugins/qtwebengine"
             "Onboarding/plugins/platforms" "Onboarding/plugins/imageformats"
             "DaVinci Control Panels Setup/plugins/platforms"
             "DaVinci Control Panels Setup/plugins/imageformats"
             "DaVinci Control Panels Setup/plugins/bearer"
             "DaVinci Control Panels Setup/AdminUtility/PlugIns/DaVinciKeyboards"
             "DaVinci Control Panels Setup/AdminUtility/PlugIns/DaVinciPanels" )
RPATH_ABS=""; for p in "${RPATH_DIRS[@]}"; do RPATH_ABS+="/opt/resolve/${p}:"; done; RPATH_ABS+="\$ORIGIN"
if command -v patchelf >/dev/null 2>&1; then
  PATCH_COUNT=0
  PATCH_FAIL=0
  PATCH_SKIP=0
  # Process all ELF files regardless of size
  while IFS= read -r -d '' f; do
    FILE_INFO="$(file -b "$f" 2>/dev/null)"
    if [[ "${FILE_INFO}" =~ ELF.*executable ]] || [[ "${FILE_INFO}" =~ ELF.*shared\ object ]]; then
      # Skip if file already has correct RPATH (optimization for re-runs)
      CURRENT_RPATH="$(patchelf --print-rpath "$f" 2>/dev/null || true)"
      if [[ "${CURRENT_RPATH}" == "${RPATH_ABS}" ]]; then
        ((PATCH_SKIP++)) || true
        continue
      fi
      if sudo patchelf --set-rpath "${RPATH_ABS}" "$f" 2>/dev/null; then
        ((PATCH_COUNT++)) || true
      else
        ((PATCH_FAIL++)) || true
        # Log failures for large files specifically as they're more critical
        FILE_SIZE=$(stat -c%s "$f" 2>/dev/null || echo 0)
        if (( FILE_SIZE > 33554432 )); then  # >32M
          warn "Failed to patch large file: ${f##/opt/resolve/}"
        fi
      fi
    fi
  done < <(find /opt/resolve -type f -print0)
  log "Patched RPATH: ${PATCH_COUNT} files (${PATCH_FAIL} failures, ${PATCH_SKIP} already correct)"
else
  warn "patchelf not found, skipping RPATH patching"
fi

# Legacy libcrypt Fix
#
# Arch Linux moved from libcrypt.so.1 to libcrypt.so.2 (via libxcrypt).
# Resolve still links against the old .so.1 version. libxcrypt-compat
# provides it, and we symlink it into Resolve's libs directory as a
# fallback in case the system-wide version isn't found in the search path.
sudo pacman -S --needed --noconfirm libxcrypt-compat || true
sudo ldconfig || true
if [[ -e /usr/lib/libcrypt.so.1 ]]; then
  sudo ln -sf /usr/lib/libcrypt.so.1 /opt/resolve/libs/libcrypt.so.1
fi

# ==================== Desktop Integration ====================
#
# Install .desktop files (app menu entries), icons, and udev rules so
# Resolve integrates properly with the desktop environment. The .desktop
# files go to /usr/share/applications/ (system-wide) and icons go to
# the hicolor icon theme at standard sizes.
log "Installing desktop entries and icons..."
declare -A DESKTOP_FILES=(
  ["/opt/resolve/share/DaVinciResolve.desktop"]="/usr/share/applications/DaVinciResolve.desktop"
  ["/opt/resolve/share/DaVinciControlPanelsSetup.desktop"]="/usr/share/applications/DaVinciControlPanelsSetup.desktop"
  ["/opt/resolve/share/blackmagicraw-player.desktop"]="/usr/share/applications/blackmagicraw-player.desktop"
  ["/opt/resolve/share/blackmagicraw-speedtest.desktop"]="/usr/share/applications/blackmagicraw-speedtest.desktop"
)
for src in "${!DESKTOP_FILES[@]}"; do
  dest="${DESKTOP_FILES[$src]}"
  if [[ -f "${src}" ]]; then
    sudo install -D -m 0644 "${src}" "${dest}"
  else
    warn "Desktop file not found: ${src}"
  fi
done

# Icons (ensure hicolor sizes present so menus show right icon)
declare -A ICON_FILES=(
  ["/opt/resolve/graphics/DV_Resolve.png"]="/usr/share/icons/hicolor/128x128/apps/davinci-resolve.png"
  ["/opt/resolve/graphics/DV_Panels.png"]="/usr/share/icons/hicolor/128x128/apps/davinci-resolve-panels-setup.png"
  ["/opt/resolve/graphics/blackmagicraw-player_256x256_apps.png"]="/usr/share/icons/hicolor/256x256/apps/blackmagicraw-player.png"
  ["/opt/resolve/graphics/blackmagicraw-speedtest_256x256_apps.png"]="/usr/share/icons/hicolor/256x256/apps/blackmagicraw-speedtest.png"
)
for src in "${!ICON_FILES[@]}"; do
  dest="${ICON_FILES[$src]}"
  if [[ -f "${src}" ]]; then
    sudo install -D -m 0644 "${src}" "${dest}"
  else
    warn "Icon file not found: ${src}"
  fi
done

sudo update-desktop-database >/dev/null 2>&1 || true
sudo gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true

# Udev rules — these give Resolve permission to access Blackmagic hardware
# devices (capture cards, control panels, editing keyboards) without root.
# Without these rules, the devices would only be accessible as root.
for r in 99-BlackmagicDevices.rules 99-ResolveKeyboardHID.rules 99-DavinciPanel.rules; do
  if [[ -f "/opt/resolve/share/etc/udev/rules.d/${r}" ]]; then
    sudo install -D -m 0644 "/opt/resolve/share/etc/udev/rules.d/${r}" "/usr/lib/udev/rules.d/${r}"
  fi
done
sudo udevadm control --reload-rules && sudo udevadm trigger || true

# ==================== XWayland Wrapper Script ====================
#
# DaVinci Resolve does NOT support native Wayland — it only works under
# X11 or XWayland. Hyprland (Omarchy's compositor) provides XWayland
# compatibility, but Resolve needs to be told to use it explicitly.
#
# This wrapper script:
#   1. Clears stale Qt lockfiles that can prevent Resolve from starting
#      (happens when Resolve crashes or is killed without clean shutdown)
#   2. Forces QT_QPA_PLATFORM=xcb (tells Qt to use X11/XWayland, not Wayland)
#   3. Enables Qt's auto screen scaling for HiDPI displays
#   4. Launches the actual Resolve binary
#
# For hybrid NVIDIA laptops (Optimus), you can uncomment the PRIME render
# offload lines to force Resolve onto the discrete GPU.
cat << 'EOF' | sudo tee /usr/local/bin/resolve-nvidia-open >/dev/null
#!/usr/bin/env bash
set -euo pipefail
# Clear stale single-instance Qt lockfiles (only if we have permission)
if [[ -r /tmp ]]; then
  for lockfile in /tmp/qtsingleapp-DaVinci*lockfile; do
    [[ -f "$lockfile" ]] && rm -f "$lockfile" 2>/dev/null || true
  done
fi
# Force XWayland under Hyprland/Wayland
export QT_QPA_PLATFORM=xcb
export QT_AUTO_SCREEN_SCALE_FACTOR=1
# For hybrid laptops, optionally force dGPU:
# export __NV_PRIME_RENDER_OFFLOAD=1
# export __GLX_VENDOR_LIBRARY_NAME=nvidia
exec /opt/resolve/bin/resolve "$@"
EOF
sudo chmod +x /usr/local/bin/resolve-nvidia-open

# Create a convenience symlink at /usr/bin/davinci-resolve so users can
# launch Resolve by typing "davinci-resolve" in any terminal. Points to
# the wrapper script so XWayland settings are always applied.
if [[ ! -e /usr/bin/davinci-resolve ]]; then
  if [[ -x /usr/local/bin/resolve-nvidia-open ]]; then
    echo -e '#!/usr/bin/env bash\nexec /usr/local/bin/resolve-nvidia-open "$@"' | sudo tee /usr/bin/davinci-resolve >/dev/null
  else
    echo -e '#!/usr/bin/env bash\nexec /opt/resolve/bin/resolve "$@"' | sudo tee /usr/bin/davinci-resolve >/dev/null
  fi
  sudo chmod +x /usr/bin/davinci-resolve
fi

# Update the system .desktop files to use our wrapper instead of launching
# Resolve directly. This ensures XWayland mode is always used regardless
# of how Resolve is launched (app menu, file association, etc.).
WRAPPER="/usr/local/bin/resolve-nvidia-open"
if [[ -f /usr/share/applications/DaVinciResolve.desktop ]]; then
  sudo sed -i "s|^Exec=.*|Exec=${WRAPPER} %U|" /usr/share/applications/DaVinciResolve.desktop
fi
if [[ -f /usr/share/applications/DaVinciResolveCaptureLogs.desktop ]]; then
  sudo sed -i "s|^Exec=.*|Exec=${WRAPPER} %U|" /usr/share/applications/DaVinciResolveCaptureLogs.desktop
fi
sudo update-desktop-database >/dev/null 2>&1 || true

# Create a user-level .desktop entry in ~/.local/share/applications/.
# User-level entries take precedence over system-level ones, so this
# ensures the wrapper is always used even if a system update overwrites
# the system .desktop file. Also sets StartupWMClass=resolve so Hyprland
# can properly identify the window for window rules and taskbar grouping.
mkdir -p "${HOME}/.local/share/applications"
cat > "${HOME}/.local/share/applications/davinci-resolve-wrapper.desktop" << EOF
[Desktop Entry]
Type=Application
Name=DaVinci Resolve
Comment=DaVinci Resolve via XWayland wrapper (NVIDIA-Open)
Exec=${WRAPPER} %U
TryExec=${WRAPPER}
Terminal=false
Icon=davinci-resolve
Categories=AudioVideo;Video;Audio;Graphics;
StartupWMClass=resolve
X-GNOME-UsesNotifications=true
EOF

update-desktop-database "${HOME}/.local/share/applications" >/dev/null 2>&1 || true
sudo gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true

echo
echo "✅ DaVinci Resolve installed to /opt/resolve"
echo "   (vendor libc++ kept; libcrypt.so.1 ensured)"
echo "   Launch from your app menu, or run: resolve-nvidia-open"
echo "   Logs: ~/.local/share/DaVinciResolve/logs/ResolveDebug.txt"
echo
