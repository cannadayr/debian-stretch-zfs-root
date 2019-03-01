#!/bin/bash -e
#
# debian-stretch-zfs-root.sh V1.00
#
# Install Debian GNU/Linux 9 Stretch to a native ZFS root filesystem
#
# (C) 2018 Hajo Noerenberg
#
#
# http://www.noerenberg.de/
# https://github.com/hn/debian-stretch-zfs-root
#
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 3.0 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/gpl-3.0.txt>.
#

### Static settings

ZPOOL=rpool-vega
TARGETDIST=stretch

PARTBIOS=1
PARTEFI=2
PARTZFS=4

SIZESWAP=16G
SIZETMP=3G
SIZEVARTMP=3G

### User settings

declare -A BYID
while read -r IDLINK; do
	BYID["$(basename "$(readlink "$IDLINK")")"]="$IDLINK"
done < <(find /dev/disk/by-id/ -type l)

for DISK in $(lsblk -I8 -dn -o name); do
	if [ -z "${BYID[$DISK]}" ]; then
		SELECT+=("$DISK" "(no /dev/disk/by-id persistent device name available)" off)
	else
		SELECT+=("$DISK" "${BYID[$DISK]}" off)
	fi
done

TMPFILE=$(mktemp)
whiptail --backtitle "$0" --title "Drive selection" --separate-output \
	--checklist "\nPlease select ZFS RAID drives\n" 20 74 8 "${SELECT[@]}" 2>"$TMPFILE"

if [ $? -ne 0 ]; then
	exit 1
fi

while read -r DISK; do
	if [ -z "${BYID[$DISK]}" ]; then
		DISKS+=("/dev/$DISK")
		ZFSPARTITIONS+=("/dev/$DISK$PARTZFS")
		EFIPARTITIONS+=("/dev/$DISK$PARTEFI")
	else
		DISKS+=("${BYID[$DISK]}")
		ZFSPARTITIONS+=("${BYID[$DISK]}-part$PARTZFS")
		EFIPARTITIONS+=("${BYID[$DISK]}-part$PARTEFI")
	fi
done < "$TMPFILE"

whiptail --backtitle "$0" --title "RAID level selection" --separate-output \
	--radiolist "\nPlease select ZFS RAID level\n" 20 74 8 \
	"RAID0" "Striped disks" off \
	"RAID1" "Mirrored disks (RAID10 for n>=4)" on \
	"RAIDZ" "Distributed parity, one parity block" off \
	"RAIDZ2" "Distributed parity, two parity blocks" off \
	"RAIDZ3" "Distributed parity, three parity blocks" off 2>"$TMPFILE"

if [ $? -ne 0 ]; then
	exit 1
fi

RAIDLEVEL=$(head -n1 "$TMPFILE" | tr '[:upper:]' '[:lower:]')

case "$RAIDLEVEL" in
  raid0)
	RAIDDEF="${ZFSPARTITIONS[*]}"
  	;;
  raid1)
	if [ $((${#ZFSPARTITIONS[@]} % 2)) -ne 0 ]; then
		echo "Need an even number of disks for RAID level '$RAIDLEVEL': ${ZFSPARTITIONS[@]}" >&2
		exit 1
	fi
	I=0
	for ZFSPARTITION in "${ZFSPARTITIONS[@]}"; do
		if [ $((I % 2)) -eq 0 ]; then
			RAIDDEF+=" mirror"
		fi
		RAIDDEF+=" $ZFSPARTITION"
		((I++)) || true
	done
  	;;
  *)
	if [ ${#ZFSPARTITIONS[@]} -lt 3 ]; then
		echo "Need at least 3 disks for RAID level '$RAIDLEVEL': ${ZFSPARTITIONS[@]}" >&2
		exit 1
	fi
	RAIDDEF="$RAIDLEVEL ${ZFSPARTITIONS[*]}"
  	;;
esac

#GRUBPKG=grub-pc
GRUBPKG=grub-efi-amd64
#if [ -d /sys/firmware/efi ]; then
#	whiptail --backtitle "$0" --title "EFI boot" --separate-output \
#		--menu "\nYour hardware supports EFI. Which boot method should be used in the new to be installed system?\n" 20 74 8 \
#		"EFI" "Extensible Firmware Interface boot" \
#		"BIOS" "Legacy BIOS boot" 2>"$TMPFILE"
#
#	if [ $? -ne 0 ]; then
#		exit 1
#	fi
#	if grep -qi EFI $TMPFILE; then
#		GRUBPKG=grub-efi-amd64
#	fi
#fi

whiptail --backtitle "$0" --title "Confirmation" \
	--yesno "\nAre you sure to destroy ZFS pool '$ZPOOL' (if existing), wipe all data of disks '${DISKS[*]}' and create a RAID '$RAIDLEVEL'?\n" 20 74

if [ $? -ne 0 ]; then
	exit 1
fi

### Start the real work
while true
do
	debootstrap --include=locales,linux-headers-amd64,linux-image-amd64 --components main,contrib,non-free $TARGETDIST /target http://deb.debian.org/debian/ && break
done

#NEWHOST=debian-$(hostid)
NEWHOST=vega
echo "$NEWHOST" >/target/etc/hostname
sed -i "1s/^/127.0.1.1\t$NEWHOST\n/" /target/etc/hosts

# Copy hostid as the target system will otherwise not be able to mount the misleadingly foreign file system
cp -va /etc/hostid /target/etc/

cat << EOF >/target/etc/fstab
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system>         <mount point>   <type>  <options>       <dump>  <pass>
#/dev/zvol/$ZPOOL/swap    none            swap    defaults        0       0
/dev/sda3                 none            swap    defaults        0       0
$ZPOOL/var                /var            zfs     defaults        0       0
$ZPOOL/var/tmp            /var/tmp        zfs     defaults        0       0
EOF

mount --rbind /dev /target/dev
mount --rbind /proc /target/proc
mount --rbind /sys /target/sys
ln -s /proc/mounts /target/etc/mtab

perl -i -pe 's/# (en_US.UTF-8)/$1/' /target/etc/locale.gen
echo 'LANG="en_US.UTF-8"' > /target/etc/default/locale
chroot /target /usr/sbin/locale-gen

chroot /target /usr/bin/apt-get update

chroot /target /usr/bin/apt-get install -y build-essential autoconf libtool gawk alien fakeroot \
                                            zlib1g-dev uuid-dev libattr1-dev libblkid-dev libselinux1-dev \
                                            libudev-dev parted lsscsi ksh libssl-dev libelf-dev \
                                            git gdebi-core python3-dev python3-setuptools python3-cffi \
                                            dkms firmware-iwlwifi

#chroot /target /usr/bin/apt-get install --yes grub2-common $GRUBPKG zfs-initramfs zfs-dkms
chroot /target /usr/bin/apt-get install --yes grub2-common $GRUBPKG

chroot /target /bin/sh -c "cd /opt && git clone --depth=1 https://github.com/zfsonlinux/zfs"
chroot /target /bin/sh -c "cd /opt/zfs && sh autogen.sh"
chroot /target /bin/sh -c "cd /opt/zfs && ./configure --with-config=user"
chroot /target /bin/sh -c "cd /opt/zfs && make pkg-utils deb-dkms"
chroot /target /bin/sh -c "cd /opt/zfs && for file in *.deb; do gdebi -q --non-interactive \$file; done"

grep -q zfs /target/etc/default/grub || perl -i -pe 's/quiet/boot=zfs quiet/' /target/etc/default/grub 
chroot /target /usr/sbin/update-grub

if [ "${GRUBPKG:0:8}" == "grub-efi" ]; then

	# "This is arguably a mis-design in the UEFI specification - the ESP is a single point of failure on one disk."
	# https://wiki.debian.org/UEFI#RAID_for_the_EFI_System_Partition
	mkdir -pv /target/boot/efi
	I=0
	for EFIPARTITION in "${EFIPARTITIONS[@]}"; do
		mkdosfs -F 32 -n EFI-$I $EFIPARTITION
		mount $EFIPARTITION /target/boot/efi
		chroot /target /usr/sbin/grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id="Debian $TARGETDIST (RAID disk $I)" --recheck --no-floppy
		umount $EFIPARTITION
		if [ $I -gt 0 ]; then
			EFIBAKPART="#"
		fi
		echo "${EFIBAKPART}PARTUUID=$(blkid -s PARTUUID -o value $EFIPARTITION) /boot/efi vfat defaults 0 1" >> /target/etc/fstab
		((I++)) || true
	done
fi

if [ -d /proc/acpi ]; then
	chroot /target /usr/bin/apt-get install --yes acpi acpid
	chroot /target service acpid stop
fi

ETHDEV=$(udevadm info -e | grep "ID_NET_NAME_PATH=" | head -n1 | cut -d= -f2)
test -n "$ETHDEV" || ETHDEV=enp0s1
echo -e "\nauto $ETHDEV\niface $ETHDEV inet dhcp\n" >>/target/etc/network/interfaces
echo -e "nameserver 8.8.8.8\nnameserver 8.8.4.4" >> /target/etc/resolv.conf

chroot /target /usr/bin/passwd
chroot /target /usr/sbin/dpkg-reconfigure tzdata

sync

#zfs umount -a

## chroot /target /bin/bash --login
## zpool import -R /target rpool

