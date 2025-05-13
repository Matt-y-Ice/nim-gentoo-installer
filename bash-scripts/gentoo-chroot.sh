#!/bin/bash
set -e

# Arguments from wrapper: $1 = hostname, $2 = username, $3 = desktop, $4.. = groups + packages
hostname="$1"
username="$2"
desktop="$3"
shift 3

# Groups: next 3 arguments
group1="$1"
group2="$2"
group3="$3"
shift 3

usergroups="$group1,$group2,$group3"
packages=("$@")

echo "[INFO] Setting hostname: $hostname"
echo "$hostname" > /etc/hostname

echo "[INFO] Syncing Portage and setting profile..."
emerge-webrsync
eselect profile set 26
emerge --oneshot app-portage/cpuid2cpuflags
echo "*/* $(cpuid2cpuflags)" > /etc/portage/package.use/00cpu-flags
echo "*/* VIDEO_CARDS: nvidia" > /etc/portage/package.use/00video_cards  # modify as needed

echo "[INFO] Setting timezone and locale..."
ln -sf ../usr/share/zoneinfo/US/Eastern /etc/localtime
locale-gen
eselect locale set 5
env-update && source /etc/profile

echo "[INFO] Mounting EFI partition..."
mkdir -p /efi
source /root/chroot_var.sh
mount "$disk" /efi

echo "[INFO] Installing kernel and systemd..."
echo -e "sys-apps/systemd boot\nsys-kernel/installkernel systemd-boot" > /etc/portage/package.use/systemd
echo "sys-kernel/installkernel dracut" > /etc/portage/package.use/installkernel
emerge sys-apps/systemd sys-kernel/installkernel
echo "quiet splash" > /etc/kernel/cmdline
emerge sys-kernel/gentoo-kernel sys-kernel/gentoo-sources

echo "[INFO] Generating fstab..."
emerge genfstab
genfstab / >> /etc/fstab

echo "[INFO] Enabling basic services..."
systemctl daemon-reexec
systemctl daemon-reload

emerge net-misc/dhcpcd net-misc/networkmanager
systemctl enable dhcpcd
systemctl enable NetworkManager

echo "[INFO] Set root password:"
passwd

systemd-machine-id-setup
systemd-firstboot --prompt

emerge sys-apps/mlocate app-shells/bash-completion net-misc/chrony \
        sys-fs/btrfs-progs sys-fs/dosfstools app-admin/sudo dev-lang/nim \
        app-eselect/eselect-repository sys-kernel/linux-firmware

eselect repository enable gentoo-zh
systemctl enable chronyd.service

echo "sys-apps/systemd boot" > /etc/portage/package.use/systemd-boot
emerge sys-apps/systemd

echo "[INFO] Installing systemd-boot..."
bootctl --esp-path=/efi install

ROOT_DISK="${disk%?}3"
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DISK")
BOOT_ENTRY_FILE=$(find /efi/loader/entries/ -name 'gentoo-*.conf' | sort | tail -n 1)
sed -i "s|^options.*|options root=UUID=$ROOT_UUID quiet splash|" "$BOOT_ENTRY_FILE"

echo "[INFO] Updating world and cleaning..."
emerge --update --deep --changed-use @world
emerge --depclean
emaint sync

rm -f /stage3.tar.*

echo "[INFO] Creating user $username with groups: $usergroups"
useradd -m -G "$usergroups" -s /bin/bash "$username"
echo "Set password for $username:"
passwd "$username"

systemctl enable gdm

echo "[INFO] Installing desktop and additional packages..."
for pkg in "${packages[@]}"; do
    echo "[INFO] Installing: $pkg"
    if ! emerge "$pkg"; then
        echo "[ERROR] Failed to install: $pkg"
        exit 1
    fi
done

echo "[INFO] All configuration complete. You may reboot and adjust UEFI boot order if needed."
