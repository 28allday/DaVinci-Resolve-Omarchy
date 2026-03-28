#!/usr/bin/env bash
# DaVinci Resolve installer for Omarchy/Arch — one-shot, self-healing, ABI-safe
# - ZIP already in ~/Downloads/
# - Assumes NVIDIA drivers are already installed and working
# - Extracts in ~/Downloads, minimal validation, AUR-style unbundling (glib/gio/gmodule only), RPATH patch
# - Installs system desktop files & icons, creates wrapper, rewires system desktop
# - Creates a user .desktop pointing to the wrapper (Hyprland-friendly)
# - Leaves vendor libc++/libc++abi in place (prevents ABI breakage)
# - Ensures legacy libcrypt.so.1 via libxcrypt-compat + fallback symlink

set -euo pipefail
log(){ echo -e "▶ $*"; }
warn(){ echo -e "⚠️  $*" >&2; }
err(){ echo -e "❌ $*" >&2; exit 1; }

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

# ---------------- Packages ----------------
# Opt-in full system upgrade (can be slow and may update kernel/NVIDIA stack unexpectedly)
if [[ "${RESOLVE_FULL_UPGRADE:-0}" == "1" ]]; then
  log "Updating system packages (RESOLVE_FULL_UPGRADE=1)..."
  sudo pacman -Syu --noconfirm
else
  log "Skipping full system upgrade (set RESOLVE_FULL_UPGRADE=1 to enable)"
  # Just sync package database without upgrading
  sudo pacman -Sy --noconfirm
fi
log "Installing required tools..."
if ! sudo pacman -S --needed --noconfirm unzip patchelf libarchive xdg-user-dirs desktop-file-utils file gtk-update-icon-cache; then
  warn "Some optional tools failed to install, continuing anyway..."
fi

# Runtime bits (KEEP vendor libc++/libc++abi)
log "Installing runtime dependencies..."
if ! sudo pacman -S --needed --noconfirm libxcrypt-compat ffmpeg4.4 glu gtk2 fuse2; then
  warn "Some runtime dependencies failed to install (may affect functionality)"
fi

# TLS path for extras downloader
if [[ ! -e /etc/pki/tls ]]; then
  sudo mkdir -p /etc/pki
  sudo ln -sf /etc/ssl /etc/pki/tls
fi

# ---------------- Extract in Downloads ----------------
NEEDED_GB=10
FREE_KB=$(df --output=avail -k "${ZIP_DIR}" | tail -n1); FREE_GB=$((FREE_KB/1024/1024))
(( FREE_GB >= NEEDED_GB )) || err "Not enough free space in ${ZIP_DIR}: ${FREE_GB} GiB < ${NEEDED_GB} GiB"

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

# ---------------- AUR-style niceties (ABI-safe) ----------------
# IMPORTANT: Do NOT touch vendor libc++/libc++abi. Only swap glib/gio/gmodule to system libs.
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

# Panels -> libs/ (best-effort)
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

rm -f "AppRun" "AppRun*" 2>/dev/null || true
rm -rf "installer" "installer*" 2>/dev/null || true
mkdir -p "bin"
ln -sf "../BlackmagicRAWPlayer/BlackmagicRawAPI" "bin/" 2>/dev/null || true
popd >/dev/null

# ---------------- Install to /opt/resolve ----------------
log "Installing Resolve to /opt/resolve…"
sudo rm -rf /opt/resolve
sudo mkdir -p /opt/resolve
if command -v rsync >/dev/null 2>&1; then
  sudo rsync -a --delete "${APPDIR}/" /opt/resolve/
else
  sudo cp -a "${APPDIR}/." /opt/resolve/
fi
sudo mkdir -p /opt/resolve/.license

# RPATH patch - done AFTER installation to /opt/resolve
# NOTE: No size limit - large libs like libQt5WebEngineCore.so (~200M) must also be patched
# to avoid mixed RPATH issues where some libs search old AppImage paths
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

# --- Ensure legacy libcrypt is available (Arch fix for Resolve) -------------
sudo pacman -S --needed --noconfirm libxcrypt-compat || true
sudo ldconfig || true
if [[ -e /usr/lib/libcrypt.so.1 ]]; then
  sudo ln -sf /usr/lib/libcrypt.so.1 /opt/resolve/libs/libcrypt.so.1
fi

# ---------------- Desktop, icons, udev (system) ----------------
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

# udev rules
for r in 99-BlackmagicDevices.rules 99-ResolveKeyboardHID.rules 99-DavinciPanel.rules; do
  if [[ -f "/opt/resolve/share/etc/udev/rules.d/${r}" ]]; then
    sudo install -D -m 0644 "/opt/resolve/share/etc/udev/rules.d/${r}" "/usr/lib/udev/rules.d/${r}"
  fi
done
sudo udevadm control --reload-rules && sudo udevadm trigger || true

# ---------------- Wrapper + helper ----------------
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

if [[ ! -e /usr/bin/davinci-resolve ]]; then
  if [[ -x /usr/local/bin/resolve-nvidia-open ]]; then
    echo -e '#!/usr/bin/env bash\nexec /usr/local/bin/resolve-nvidia-open "$@"' | sudo tee /usr/bin/davinci-resolve >/dev/null
  else
    echo -e '#!/usr/bin/env bash\nexec /opt/resolve/bin/resolve "$@"' | sudo tee /usr/bin/davinci-resolve >/dev/null
  fi
  sudo chmod +x /usr/bin/davinci-resolve
fi

# Point system desktop launchers at the wrapper
WRAPPER="/usr/local/bin/resolve-nvidia-open"
if [[ -f /usr/share/applications/DaVinciResolve.desktop ]]; then
  sudo sed -i "s|^Exec=.*|Exec=${WRAPPER} %U|" /usr/share/applications/DaVinciResolve.desktop
fi
if [[ -f /usr/share/applications/DaVinciResolveCaptureLogs.desktop ]]; then
  sudo sed -i "s|^Exec=.*|Exec=${WRAPPER} %U|" /usr/share/applications/DaVinciResolveCaptureLogs.desktop
fi
sudo update-desktop-database >/dev/null 2>&1 || true

# ---------------- User-level desktop entry (takes precedence) ----------------
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
