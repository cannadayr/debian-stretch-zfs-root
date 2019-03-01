#!/bin/bash

#if [ "${GRUBPKG:0:8}" == "grub-efi" ]; then

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
#fi

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

