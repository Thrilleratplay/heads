#!/bin/bash
# Launches kexec from saved configuration entries
set -e -o pipefail
. /tmp/config
. /etc/functions.sh

dryrun="n"
printfiles="n"
printinitrd="n"
while getopts "b:e:r:a:o:fi" arg; do
	case $arg in
		b) bootdir="$OPTARG" ;;
		e) entry="$OPTARG" ;;
		r) cmdremove="$OPTARG" ;;
		a) cmdadd="$OPTARG" ;;
		o) override_initrd="$OPTARG" ;;
		f) dryrun="y"; printfiles="y" ;;
		i) dryrun="y"; printinitrd="y" ;;
	esac
done

if [ -z "$bootdir" -o -z "$entry" ]; then
	die "Usage: $0 -b /boot -e 'kexec params|...|...'"
fi

bootdir="${bootdir%%/}"

kexectype=$(echo "$entry" | cut -d\| -f2)
kexecparams=$(echo "$entry" | cut -d\| -f3- | tr '|' '\n')
kexeccmd="kexec"

cmdadd="$CONFIG_BOOT_KERNEL_ADD $cmdadd"
cmdremove="$CONFIG_BOOT_KERNEL_REMOVE $cmdremove"

fix_file_path() {
	if [ "$printfiles" = "y" ]; then
		# output file relative to local boot directory
		echo ".$firstval"
	fi

	filepath="$bootdir$firstval"

	if ! [ -r "$filepath" ]; then
		die "Failed to find file $firstval"
	fi
}

adjusted_cmd_line="n"
adjust_cmd_line() {
	if [ -n "$cmdremove" ]; then
		for i in $cmdremove; do
			cmdline="${cmdline//$i/}"
		done
	fi

	if [ -n "$cmdadd" ]; then
		cmdline="$cmdline $cmdadd"
	fi
	adjusted_cmd_line="y"
}

module_number="1"
while read line
do
	key=$(echo "$line" | cut -d\  -f1)
	firstval=$(echo "$line" | cut -d\  -f2)
	restval=$(echo "$line" | cut -d\  -f3-)
	if [ "$key" = "kernel" ]; then
		fix_file_path
		if [ "$kexectype" = "xen" ]; then
			# always use xen with custom arguments
			kexeccmd="$kexeccmd -l $filepath"
			kexeccmd="$kexeccmd --command-line \"$restval no-real-mode reboot=no vga=current\""
		elif [ "$kexectype" = "multiboot" ]; then
			kexeccmd="$kexeccmd -l $filepath"
			kexeccmd="$kexeccmd --command-line \"$restval\""
		else
			kexeccmd="$kexeccmd -l $filepath"
		fi
	fi
	if [ "$key" = "module" ]; then
		fix_file_path
		cmdline="$restval"
		if [ "$kexectype" = "xen" ]; then
			if [ "$module_number" -eq 1 ]; then
				adjust_cmd_line
			elif [ "$module_number" -eq 2 ]; then
				if [ "$printinitrd" = "y" ]; then
					# output the current path to initrd
					echo "$filepath"
				fi
				if [ -n "$override_initrd" ]; then
					filepath="$override_initrd"
				fi
			fi
		fi
		module_number=$((module_number + 1))
		kexeccmd="$kexeccmd --module \"$filepath $cmdline\""
	fi
	if [ "$key" = "initrd" ]; then
		fix_file_path
		if [ "$printinitrd" = "y" ]; then
			# output the current path to initrd
			echo "$filepath"
		fi
		if [ -n "$override_initrd" ]; then
			filepath="$override_initrd"
		fi
		kexeccmd="$kexeccmd --initrd=$filepath"
	fi
	if [ "$key" = "append" ]; then
		cmdline="$firstval $restval"
		adjust_cmd_line
		kexeccmd="$kexeccmd --append=\"$cmdline\""
	fi
done << EOF
$kexecparams
EOF

if [ "$adjusted_cmd_line" = "n" ]; then
	if [ "$kexectype" = "elf" ]; then
		kexeccmd="$kexeccmd --append=\"$cmdadd\""
	else
		die "Failed to add required kernel commands: $cmdadd"
	fi
fi

if [ "$dryrun" = "y" ]; then exit 0; fi

echo "Loading the new kernel:"
echo "$kexeccmd"
eval "$kexeccmd" \
|| die "Failed to load the new kernel"

echo "Starting the new kernel"
exec kexec -e
