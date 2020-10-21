#!/bin/sh
# Shell functions for most initialization scripts

die() {
	echo >&2 "$*";
	exit 1;
}

warn() {
	echo >&2 "$*";
}

recovery() {
	echo >&2 "!!!!! $*"

	# Remove any temporary secret files that might be hanging around
	# but recreate the directory so that new tools can use it.
	shred -n 10 -z -u /tmp/secret/* 2> /dev/null
	rm -rf /tmp/secret
	mkdir -p /tmp/secret

	# ensure /tmp/config exists for recovery scripts that depend on it
	touch /tmp/config

	if [ "$CONFIG_TPM" = y ]; then
		tpm extend -ix 4 -ic recovery
	fi

	while true;
	do
		echo >&2 "!!!!! Starting recovery shell"
		sleep 1

		if [ -x /bin/setsid ]; then
			/bin/setsid -c /bin/ash
		else
			/bin/ash
		fi
		# clear screen
		printf "\033c"
	done
}

pause_recovery() {
	read -r -p 'Hit enter to proceed to recovery shell:'
	recovery "$*"
}

pcrs() {
	head -8 /sys/class/tpm/tpm0/pcrs
}

confirm_totp()
{
	prompt="$1"
	last_half=X
	unset totp_confirm

	while true; do

		# update the TOTP code every thirty seconds
		date=$(date "+%Y-%m-%d %H:%M:%S")
		seconds=$(date "+%s")
		half=$((( seconds % 60 ) / 30))
		if [ "$CONFIG_TPM" != y ]; then
			TOTP="NO TPM"
		elif [ "$half" != "$last_half" ]; then
			last_half=$half;
			TOTP=$(unseal-totp) \
			|| recovery "TOTP code generation failed"
		fi

		echo -n "$date $TOTP: "

		# read the first character, non-blocking
		read -r \
			-t 1 \
			-n 1 \
			-s \
			-p "$prompt" \
			totp_confirm \
		&& break

		# nothing typed, redraw the line
		echo -ne '\r'
	done

	# clean up with a newline
	echo
}

enable_usb()
{
	if [ "$CONFIG_LINUX_USB_COMPANION_CONTROLLER" = y ]; then
		if ! lsmod | grep -q uhci_hcd; then
			insmod /lib/modules/uhci-hcd.ko \
			|| die "uhci_hcd: module load failed"
		fi
		if ! lsmod | grep -q ohci_hcd; then
			insmod /lib/modules/ohci-hcd.ko \
			|| die "ohci_hcd: module load failed"
		fi
		if ! lsmod | grep -q ohci_pci; then
			insmod /lib/modules/ohci-pci.ko \
			|| die "ohci_pci: module load failed"
		fi
	fi
	if ! lsmod | grep -q ehci_hcd; then
		insmod /lib/modules/ehci-hcd.ko \
		|| die "ehci_hcd: module load failed"
	fi
	if ! lsmod | grep -q ehci_pci; then
		insmod /lib/modules/ehci-pci.ko \
		|| die "ehci_pci: module load failed"
	fi
	if ! lsmod | grep -q xhci_hcd; then
		insmod /lib/modules/xhci-hcd.ko \
		|| die "xhci_hcd: module load failed"
	fi
	if ! lsmod | grep -q xhci_pci; then
		insmod /lib/modules/xhci-pci.ko \
		|| die "xhci_pci: module load failed"
		sleep 2
	fi
}

confirm_gpg_card()
{
	read -r \
		-n 1 \
		-p "Please confirm that your GPG card is inserted [Y/n]: " \
		card_confirm
	echo

	if [ "$card_confirm" != "y" ] && [ "$card_confirm" != "Y" ] && [ -n "$card_confirm" ] \
	; then
		die "gpg card not confirmed"
	fi

	# setup the USB so we can reach the GPG card
	enable_usb

	echo -e "\nVerifying presence of GPG card...\n"
	# ensure we don't exit without retrying
	errexit=$(set -o | grep errexit | awk '{print $2}')
	set +e
	if ! (gpg --card-status > /dev/null \ || die "gpg card read failed"); then
	  # prompt for reinsertion and try a second time
	  read -n1 -r -p \
	      "Can't access GPG key; remove and reinsert, then press Enter to retry. " \
	      ignored
	  # restore prev errexit state
	  if [ "$errexit" = "on" ]; then
	    set -e
	  fi
	fi
	# restore prev errexit state
	if [ "$errexit" = "on" ]; then
	  set -e
	fi
}


check_tpm_counter()
{
  LABEL=${2:-3135106223}
	# if the /boot.hashes file already exists, read the TPM counter ID
	# from it.
	if [ -r "$1" ]; then
		TPM_COUNTER=$(grep counter- "$1" | cut -d- -f2)
	else
		warn "$1 does not exist; creating new TPM counter"
		read -r -s -p "TPM Owner password: " tpm_password
		echo
		tpm counter_create \
			-pwdo "$tpm_password" \
			-pwdc '' \
			-la "$LABEL" \
		| tee /tmp/counter \
		|| die "Unable to create TPM counter"
		TPM_COUNTER=$(cut -d: -f1 < /tmp/counter)
	fi

	if [ -z "$TPM_COUNTER" ]; then
		die "$1: TPM Counter not found?"
	fi
}

read_tpm_counter()
{
	tpm counter_read -ix "$1" | tee "/tmp/counter-$1" \
	|| die "Counter read failed"
}

increment_tpm_counter()
{
	tpm counter_increment -ix "$1" -pwdc '' \
		| tee "/tmp/counter-$1" \
	|| die "Counter increment failed"
}

check_config() {
	if [ ! -d /tmp/kexec ]; then
		mkdir /tmp/kexec \
		|| die 'Failed to make kexec tmp dir'
	else
		rm -rf /tmp/kexec/* \
		|| die 'Failed to empty kexec tmp dir'
	fi

	if [ ! -r "$1/kexec.sig" ]; then
		return
	fi

	KEXEC_FILE_COUNT=$(find "$1/kexec*.txt" | wc -l)
	if [ $((KEXEC_FILE_COUNT)) -eq 0 ]; then
		return
	fi

	if [ "$2" != "force" ]; then
		KEXEC_FILES=$(find "$1/kexec*.txt");
		if ! sha256sum "$KEXEC_FILES" | gpgv "$1/kexec.sig" - ; then
			die 'Invalid signature on kexec boot params'
		fi
	fi

	echo "+++ Found verified kexec boot params"
	cp "$1/kexec*.txt" /tmp/kexec \
	|| die "Failed to copy kexec boot params to tmp"
}

preserve_rom() {
	new_rom="$1"

	for old_file in $(cbfs -t 50 -l 2>/dev/null | grep "^heads/"); do
		new_file=$(cbfs -o "$1" -l | grep -x "$old_file")
		if [ -z "$new_file" ]; then
			echo "+++ Adding $old_file to $1"
			cbfs -t 50 -r "$old_file" >/tmp/rom.$$ \
			|| die "Failed to read cbfs file from ROM"
			cbfs -o "$1" -a "$old_file" -f /tmp/rom.$$ \
			|| die "Failed to write cbfs file to new ROM file"
		fi
	done
}
replace_config() {
	CONFIG_FILE=$1
	CONFIG_OPTION=$2
	NEW_SETTING=$3

	touch "$CONFIG_FILE"
# first pull out the existing option from the global config and place in a tmp file
	awk "gsub(\"^export ${CONFIG_OPTION}=.*\",\"export ${CONFIG_OPTION}=\\\"${NEW_SETTING}\\\"\")" /tmp/config > "${CONFIG_FILE}.tmp"
	awk "gsub(\"^${CONFIG_OPTION}=.*\",\"${CONFIG_OPTION}=\\\"${NEW_SETTING}\\\"\")" /tmp/config >> "${CONFIG_FILE}.tmp"

# then copy any remaining settings from the existing config file, minus the option you changed
	grep -v "^export ${CONFIG_OPTION}=" "${CONFIG_FILE}" | grep -v "^${CONFIG_OPTION}=" >> "${CONFIG_FILE}.tmp" || true
  sort "${CONFIG_FILE}.tmp" | uniq > "${CONFIG_FILE}"
	rm -f "${CONFIG_FILE}.tmp"
}
combine_configs() {
	cat /etc/config* > /tmp/config
}

update_checksums()
{
	# clear screen
	printf "\033c"
	# ensure /boot mounted
	if ! grep -q /boot /proc/mounts ; then
		mount -o ro /boot \
		|| recovery "Unable to mount /boot"
	fi

	# remount RW
	mount -o rw,remount /boot

	# sign and auto-roll config counter
	extparam=
	if [ "$CONFIG_TPM" = "y" ]; then
		extparam=-r
	fi
	if ! kexec-sign-config -p /boot -u $extparam ; then
	  echo "Failed to sign default config; press Enter to continue."
	  read -r
	fi

	# switch back to ro mode
	mount -o ro,remount /boot
}

# detect and set /boot device
# mount /boot if successful
detect_boot_device()
{
	# unmount /boot to be safe
	cd / && umount /boot 2>/dev/null

	# check $CONFIG_BOOT_DEV if set/valid
	if [ -e "$CONFIG_BOOT_DEV" ]; then
		if mount -o ro "$CONFIG_BOOT_DEV" /boot >/dev/null 2>&1; then
			if ls -d /boot/grub* >/dev/null 2>&1; then
				# CONFIG_BOOT_DEV is valid device and contains an installed OS
				return 0
			fi
		fi
	fi

	# generate list of possible boot devices
	fdisk -l | grep "Disk" | cut -f2 -d " " | cut -f1 -d ":" > /tmp/disklist

	# filter out extraneous options
	# > /tmp/boot_device_list
	DISK_LIST=$(cat /tmp/disklist)
	for i in $DISK_LIST; do
		# remove block device from list if numeric partitions exist, since not bootable
		DEV_NUM_PARTITIONS=$(find "$i*" | wc -l)
		DEV_NUM_PARTITIONS_SANS_BLOCK=$((DEV_NUM_PARTITIONS-1))
		if [ $((DEV_NUM_PARTITIONS_SANS_BLOCK)) -eq 0 ]; then
			echo "$i" >> /tmp/boot_device_list
		else
			find "$i*" | tail -$((DEV_NUM_PARTITIONS_SANS_BLOCK)) >> /tmp/boot_device_list
		fi
	done

	# iterate thru possible options and check for grub dir
	BOOT_DEVICE_LIST=$(cat /tmp/boot_device_list)
	for i in $BOOT_DEVICE_LIST; do
		umount /boot 2>/dev/null
		if mount -o ro "$i" /boot >/dev/null 2>&1; then
			if ls -d /boot/grub* >/dev/null 2>&1; then
				CONFIG_BOOT_DEV="$i"
				return 0
			fi
		fi
	done

	# no valid boot device found
	echo "Unable to locate /boot files on any mounted disk"
	umount /boot 2>/dev/null
	return 1
}
