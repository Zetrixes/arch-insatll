#!/usr/bin/env bash
set -eo pipefail
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
NC="\033[0m"
ok()   { echo -e "${GREEN}[OK] $*${NC}"; }
info() { echo -e "${YELLOW}[INFO] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
err()  { echo -e "${RED}[ERROR] $*${NC}"; }
trap 'err "Skript upal na stroke $LINENO"; exit 1' ERR
retry() {
    local n=0 max=5
    until "$@"; do
        n=$((n+1))
        if (( n >= max )); then err "Komanda '$*' ne srabotala."; return 1; fi
        sleep 3
    done
}

USER_NAME="Zetrixes"
USER_PASS="14885200"
ROOT_PASS="2416"
HOST_NAME="serpantinum-pc"

if [[ "$(id -u)" -ne 0 ]]; then err "Zapustite ot root!"; exit 1; fi

clear
echo -e "${YELLOW}====================================================${NC}"
echo -e "${GREEN}                ARCH INSTALLER v1                    ${NC}"
echo -e "${YELLOW}====================================================${NC}"

if [[ ! -d /sys/firmware/efi/efivars ]]; then err "Trebuetsya UEFI!"; exit 1; fi
if ! ping -c 1 -W 3 archlinux.org &>/dev/null; then err "Net interneta!"; exit 1; fi

timedatectl set-ntp true
info "Sinxronizatsiya baz..."
pacman -Sy --noconfirm --disable-download-timeout

CPU_VENDOR=$(grep -m 1 vendor_id /proc/cpuinfo | awk '{print $3}')
[[ "$CPU_VENDOR" == "GenuineIntel" ]] && MICROCODE="intel-ucode" || MICROCODE="amd-ucode"
echo -e "CPU: $MICROCODE"

GPU_PKGS=""
if lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | grep -iq 'nvidia'; then
    GPU_PKGS="nvidia nvidia-utils lib32-nvidia-utils lib32-mesa"
elif lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | grep -iq 'amd'; then
    GPU_PKGS="mesa vulkan-radeon lib32-mesa lib32-vulkan-radeon"
elif lspci -nn 2>/dev/null | grep -iE 'vga|3d|display' | grep -iq 'intel'; then
    GPU_PKGS="mesa vulkan-intel lib32-mesa lib32-vulkan-intel"
fi

echo -e "\n${YELLOW}Diski:${NC}"
lsblk -d -n -o NAME,SIZE,TYPE,MODEL 2>/dev/null | grep -E 'disk|nvme' || lsblk -d -n -o NAME,SIZE,TYPE,MODEL

read -rp "Imya diska (naprimer sda, vda): " DISK_NAME
DISK_NAME=$(echo "$DISK_NAME" | tr -d '\r' | xargs)
[[ ! -b "/dev/$DISK_NAME" ]] && { err "Disk ne nayden!"; exit 1; }
DISK="/dev/$DISK_NAME"

echo -e "\n${RED}VES' DISK $DISK BUDET OTFORMATIROVAN!${NC}"
read -rp "Prodolzhit'? (y/N): " CONFIRM
CONFIRM=$(echo "$CONFIRM" | tr -d '\r' | xargs)
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && { echo "Otmena."; exit 0; }

pacman -S --noconfirm --needed reflector
sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf
sed -i '/^\[multilib\]/{n;s/^#Include/Include/}' /etc/pacman.conf

info "Poisk rabochikh zerkal cherez reflector..."
reflector --country 'Russia,Germany,France,Netherlands,United States,Japan' \
    --age 12 --protocol https --sort rate --latest 20 \
    --save /etc/pacman.d/mirrorlist 2>/dev/null || {
    warn "Reflector ne srabotal, ispol'zuyu oficial'nyy generator..."
    curl -s "https://archlinux.org/mirrorlist/?country=RU&country=DE&country=FR&protocol=https&use_mirror_status=on" \
        | sed -e 's/^#Server/Server/' -e '/^#/d' > /etc/pacman.d/mirrorlist
}

if ! grep -q '^Server' /etc/pacman.d/mirrorlist; then
    err "Mirrorlist pust!"
    exit 1
fi

ok "Naydeno zerkal: $(grep -c '^Server' /etc/pacman.d/mirrorlist)"
pacman -Syy --noconfirm

swapoff -a 2>/dev/null || true
umount -R /mnt 2>/dev/null || true
wipefs -a "$DISK"
parted -s "$DISK" mklabel gpt
parted -s "$DISK" mkpart ESP fat32 1MiB 513MiB
parted -s "$DISK" set 1 esp on
parted -s "$DISK" mkpart primary ext4 513MiB 100%
partprobe "$DISK" 2>/dev/null || true
sleep 2

if [[ "$DISK_NAME" == nvme* || "$DISK_NAME" == vd* ]]; then
    PART_BOOT="${DISK}p1"; PART_ROOT="${DISK}p2"
else
    PART_BOOT="${DISK}1"; PART_ROOT="${DISK}2"
fi

mkfs.fat -F32 "$PART_BOOT"
mkfs.ext4 -q -F "$PART_ROOT"
mount "$PART_ROOT" /mnt
mkdir -p /mnt/boot
mount "$PART_BOOT" /mnt/boot

info "Ustanovka bazovoy sistemy..."
pacstrap -K /mnt base base-devel sudo linux-zen linux-zen-headers \
    $MICROCODE $GPU_PKGS networkmanager git nano vim grub efibootmgr reflector

genfstab -U /mnt >> /mnt/etc/fstab
ROOT_UUID=$(blkid -s UUID -o value "$PART_ROOT")

info "Nastroyka v chroot..."
arch-chroot /mnt /bin/bash <<CHROOT_EOF
set -e

ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
hwclock --systohc

cat > /etc/locale.gen <<'EOT'
en_US.UTF-8 UTF-8
ru_RU.UTF-8 UTF-8
EOT
locale-gen
echo "LANG=ru_RU.UTF-8" > /etc/locale.conf
echo "KEYMAP=ru" > /etc/vconsole.conf
echo "$HOST_NAME" > /etc/hostname

cat > /etc/hosts <<EOT
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOST_NAME.localdomain $HOST_NAME
EOT

sed -i 's/^#\[multilib\]/[multilib]/' /etc/pacman.conf
sed -i '/^\[multilib\]/{n;s/^#Include/Include/}' /etc/pacman.conf

reflector --country 'Russia,Germany,France,Netherlands,United States,Japan' \
    --age 12 --protocol https --sort rate --latest 20 \
    --save /etc/pacman.d/mirrorlist 2>/dev/null || {
    curl -s "https://archlinux.org/mirrorlist/?country=RU&country=DE&country=FR&protocol=https&use_mirror_status=on" \
        | sed -e 's/^#Server/Server/' -e '/^#/d' > /etc/pacman.d/mirrorlist
}

pacman -Syy --noconfirm

echo "root:$ROOT_PASS" | chpasswd

useradd -m -G wheel -s /bin/bash "$USER_NAME"
echo "$USER_NAME:$USER_PASS" | chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > /etc/sudoers.d/wheel

systemctl enable NetworkManager
systemctl enable reflector.timer

# GRUB установка
grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB --removable

cat > /etc/default/grub <<'EOT'
GRUB_DEFAULT=0
GRUB_TIMEOUT=5
GRUB_DISTRIBUTOR="Arch"
GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"
GRUB_CMDLINE_LINUX=""
EOT

grub-mkconfig -o /boot/grub/grub.cfg

# ИСПРАВЛЕНИЕ: ищем grubx64.efi во всех возможных местах
echo "Poisk grubx64.efi..."
GRUB_EFI=""
for path in /boot/EFI/GRUB/grubx64.efi /boot/EFI/grub/grubx64.efi /boot/EFI/BOOT/grubx64.efi; do
    if [[ -f "$path" ]]; then
        GRUB_EFI="$path"
        echo "Nayden: $path"
        break
    fi
done

if [[ -z "$GRUB_EFI" ]]; then
    echo "GRUB_EFI ne nayden, ishem cherez find..."
    GRUB_EFI=$(find /boot -name "grubx64.efi" 2>/dev/null | head -n 1)
    [[ -n "$GRUB_EFI" ]] && echo "Nayden cherez find: $GRUB_EFI"
fi

if [[ -n "$GRUB_EFI" && -f "$GRUB_EFI" ]]; then
    mkdir -p /boot/EFI/BOOT
    cp "$GRUB_EFI" /boot/EFI/BOOT/BOOTX64.EFI
    echo "Fallback kopiya sozdana: /boot/EFI/BOOT/BOOTX64.EFI"
else
    echo "WARNING: grubx64.efi ne nayden, no GRUB ustanovlen"
fi

mkinitcpio -P
echo "GRUB ustanovlen!"
CHROOT_EOF

umount -R /mnt

echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}[SUCCESS] Ustanovka zavershena!${NC}"
echo -e "${YELLOW}Login: Zetrixes | Password: 14885200${NC}"
echo -e "${YELLOW}Root password: 2416${NC}"
echo -e "${YELLOW}1. reboot${NC}"
echo -e "${YELLOW}2. Iz'yat' ISO v VirtualBox${NC}"
echo -e "${GREEN}====================================================${NC}"
