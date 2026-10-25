#!/bin/bash
#
# Build the Try layer: what turns the root image into a live Omarchy session
# when the ISO's "Try Omarchy" entry boots it (configs/airootfs/etc/initcpio/
# hooks/omarchy_try). The image itself stays exactly the bytes an install
# writes; this layer goes on top of it, read-only, under a tmpfs.
#
# Usage: build-try-layer.sh <image root> <output.sfs>
#
#   image root   The image's subvolume, mounted (build-root-image.sh's $root).
#   output.sfs   Where to write the layer.
#
# It runs, once, the parts of an install that a live session needs, against an
# overlay of the image, and keeps the overlay's upper directory:
#
#   - user omarchy with no password, sudo without one, SDDM logging it in;
#   - omarchy-provision-user for it, as the installer runs it;
#   - the services an installed system enables for its desktop and network;
#   - nothing that touches a disk: no Snapper or Limine timers, no mdraid or
#     LVM autoassembly, no automount of other disks.
#
# Needs a privileged environment: an overlay mount and arch-chroot.

set -euo pipefail

image_root="${1:-}"
output="${2:-}"
if [[ -z $image_root || -z $output ]]; then
  echo "Usage: build-try-layer.sh <image root> <output.sfs>" >&2
  exit 1
fi

TRY_USER=omarchy

work=$(mktemp -d /tmp/omarchy-try-layer.XXXXXX)
upper="$work/upper"
merged="$work/merged"

cleanup() {
  local status=$?
  set +e
  if mountpoint -q "$merged" 2>/dev/null; then
    umount -R "$merged" || { echo "WARNING: $merged is still mounted; leaving $work" >&2; return $status; }
  fi
  if mountpoint -q "$work" 2>/dev/null; then
    umount "$work" || { echo "WARNING: $work is still mounted" >&2; return $status; }
  fi
  rm -rf "$work"
  return $status
}
trap cleanup EXIT

# On a tmpfs of its own: overlayfs refuses an upper directory on another
# overlay, which is what /tmp is inside the build container.
mount -t tmpfs -o mode=0755 omarchy-try-layer "$work"
mkdir -p "$upper" "$work/work" "$merged"

# index, metacopy and redirect_dir off: the upper directory then holds plain
# files and whiteouts only, nothing that refers back to this particular lower
# layer, so it stays valid when it is mounted over the image again at boot.
mount -t overlay try-layer \
  -o "lowerdir=$image_root,upperdir=$upper,workdir=$work/work,index=off,metacopy=off,redirect_dir=off" \
  "$merged"

in_try() {
  arch-chroot "$merged" "$@"
}

# The user. passwd -d: no password, as most live sessions have; the
# session's sudo needs none either.
in_try useradd -m -G wheel -s /bin/bash "$TRY_USER"
in_try passwd -d "$TRY_USER" >/dev/null
install -d -m 0750 "$merged/etc/sudoers.d"
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$TRY_USER" >"$merged/etc/sudoers.d/10-omarchy-try"
chmod 0440 "$merged/etc/sudoers.d/10-omarchy-try"

# The user's desktop, as the installer's run_chroot_finalizer makes it
# (orchestrator/phases_impl.py), offline as there.
in_try runuser -u "$TRY_USER" -- env \
  HOME="/home/$TRY_USER" USER="$TRY_USER" LOGNAME="$TRY_USER" \
  OMARCHY_PATH=/usr/share/omarchy OMARCHY_INSTALL=/usr/share/omarchy/install \
  OMARCHY_INSTALL_USER="$TRY_USER" MISE_OFFLINE=1 \
  /usr/bin/omarchy-provision-user --force --first-install

# Services Omarchy's install/config/enable-services.sh enables that a live
# desktop needs. Not cups, avahi or docker: nothing to print to, browse or run.
for unit in systemd-resolved.service NetworkManager.service power-profiles-daemon.service \
  sddm.service systemd-oomd.service; do
  in_try systemctl enable "$unit" >/dev/null 2>&1 || echo "WARNING: could not enable $unit" >&2
done
in_try systemctl mask NetworkManager-wait-online.service >/dev/null 2>&1 || true
ln -sf ../run/systemd/resolve/stub-resolv.conf "$merged/etc/resolv.conf"

# SDDM straight into the session, as configure_login does for an encrypted
# install.
install -d "$merged/etc/sddm.conf.d"
cat >"$merged/etc/sddm.conf.d/99-omarchy-login.conf" <<EOF
[Theme]
Current=omarchy

[Users]
RememberLastUser=true
RememberLastSession=true
EOF
cat >"$merged/etc/sddm.conf.d/autologin.conf" <<EOF
[Autologin]
User=$TRY_USER
Session=omarchy.desktop
EOF

# Nothing in Try touches a disk.
#   Snapper and limine-snapper-sync work on the installed btrfs and its ESP;
#   / here is an overlay.
for unit in snapper-timeline.timer snapper-cleanup.timer snapper-boot.timer \
  limine-snapper-sync.service; do
  in_try systemctl mask "$unit" >/dev/null 2>&1 || true
done
#   mdadm's udev rule assembles RAID members it finds, and assembly can write
#   to them (a resync); LVM activates volume groups on its own.
install -d "$merged/etc/udev/rules.d"
ln -sf /dev/null "$merged/etc/udev/rules.d/64-md-raid-assembly.rules"
ln -sf /dev/null "$merged/etc/udev/rules.d/69-dm-lvm.rules"
#   Omarchy's Hyprland autostart runs `udiskie --automount`, and a command
#   line option beats udiskie's config file. /usr/local/bin is ahead of
#   /usr/bin on PATH, so this wrapper turns it into --no-automount: Try mounts
#   nothing on its own and never asks to unlock a disk.
install -Dm755 /dev/stdin "$merged/usr/local/bin/udiskie" <<'EOF'
#!/bin/bash
args=()
for arg in "$@"; do
  case $arg in
  -a | --automount) args+=(--no-automount) ;;
  *) args+=("$arg") ;;
  esac
done
exec /usr/bin/udiskie "${args[@]}"
EOF

# The way to the installer: reboot and pick Install in the boot menu.
install -Dm755 /dev/stdin "$merged/usr/local/bin/omarchy-try-install" <<'EOF'
#!/bin/bash
# Try Omarchy runs from the stick. Installing is the other entry of its boot
# menu; offer the reboot that gets there.
if gum confirm "Omarchy installs from the boot menu: restart now and pick \"Install Omarchy\"?"; then
  systemctl reboot
fi
EOF
install -Dm644 /dev/stdin "$merged/usr/local/share/applications/omarchy-try-install.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Install Omarchy
Comment=Restart into the installer
Exec=xdg-terminal-exec omarchy-try-install
Icon=system-software-install
Terminal=false
EOF

# Built on the build host's clock and identity; the session makes its own.
: >"$merged/etc/machine-id"

umount -R "$merged"

# Keep xattrs: overlayfs marks opaque directories with one, and a whiteout is
# a 0:0 character device; both must survive for the layer to hide what it
# deleted.
mksquashfs "$upper" "$output" -comp zstd -Xcompression-level 3 -noappend -quiet
echo "Try layer: $(du -h "$output" | cut -f1) at $output"
