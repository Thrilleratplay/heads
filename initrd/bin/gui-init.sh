#!/bin/bash
# Boot from a local disk installation

BOARD_NAME=${CONFIG_BOARD_NAME:-${CONFIG_BOARD}}
MAIN_MENU_TITLE="${BOARD_NAME} | Heads Boot Menu"
export BG_COLOR_WARNING="${CONFIG_WARNING_BG_COLOR:-"--background-gradient 0 0 0 150 125 0"}"
export BG_COLOR_ERROR="${CONFIG_ERROR_BG_COLOR:-"--background-gradient 0 0 0 150 0 0"}"

. /etc/functions.sh
. /tmp/config

mount_boot()
{

  # Mount local disk if it is not already mounted
  while ! grep -q /boot /proc/mounts ; do
    # try to mount if CONFIG_BOOT_DEV exists
    if [ -e "$CONFIG_BOOT_DEV" ]; then
      mount -o ro $CONFIG_BOOT_DEV /boot
      [[ $? -eq 0 ]] && continue
    fi

    # CONFIG_BOOT_DEV doesn't exist or couldn't be mounted, so give user options
    whiptail $BG_COLOR_ERROR --clear --title "ERROR: No Bootable OS Found!" \
        --menu "    No bootable OS was found on the default boot device $CONFIG_BOOT_DEV.
    How would you like to proceed?" 30 90 4 \
        'b' ' Select a new boot device' \
        'u' ' Boot from USB' \
        'm' ' Continue to the main menu' \
        'x' ' Exit to recovery shell' \
        2>/tmp/whiptail || recovery "GUI menu failed"

    option=$(cat /tmp/whiptail)
    case "$option" in
      b )
        config-gui.sh boot_device_select
        if [ $? -eq 0 ]; then
          # update CONFIG_BOOT_DEV
          . /tmp/config
        fi
        ;;
      u )
        exec /bin/usb-init
        ;;
      m )
        break
        ;;
      * )
        recovery "User requested recovery shell"
        ;;
    esac
  done
}
verify_global_hashes()
{
  # Check the hashes of all the files, ignoring signatures for now
  check_config /boot force
  TMP_HASH_FILE="/tmp/kexec/kexec_hashes.txt"
  TMP_PACKAGE_TRIGGER_PRE="/tmp/kexec/kexec_package_trigger_pre.txt"
  TMP_PACKAGE_TRIGGER_POST="/tmp/kexec/kexec_package_trigger_post.txt"

  if ( cd /boot && sha256sum -c "$TMP_HASH_FILE" > /tmp/hash_output ) then
    return 0
  elif [ ! -f $TMP_HASH_FILE ]; then
    if (whiptail $BG_COLOR_ERROR --clear --title 'ERROR: Missing Hash File!' \
      --yesno "The file containing hashes for /boot is missing!\n\nIf you are setting this system up for the first time, select Yes to update\nyour list of checksums.\n\nOtherwise this could indicate a compromise and you should select No to\nreturn to the main menu.\n\nWould you like to update your checksums now?" 30 90) then
      update_checksums
    fi
    return 1
  else
    CHANGED_FILES=$(grep -v 'OK$' /tmp/hash_output | cut -f1 -d ':')

    # if files changed before package manager started, show stern warning
    if [ -f "$TMP_PACKAGE_TRIGGER_PRE" ]; then
      PRE_CHANGED_FILES=$(grep '^CHANGED_FILES' $TMP_PACKAGE_TRIGGER_POST | cut -f 2 -d '=' | tr -d '"')
      TEXT="The following files failed the verification process BEFORE package updates ran:\n${PRE_CHANGED_FILES}\n\nCompare against the files Heads has detected have changed:\n${CHANGED_FILES}\n\nThis could indicate a compromise!\n\nWould you like to update your checksums anyway?"

    # if files changed after package manager started, probably caused by package manager
    elif [ -f "$TMP_PACKAGE_TRIGGER_POST" ]; then
      LAST_PACKAGE_LIST=$(grep -E "^(Install|Remove|Upgrade|Reinstall):" $TMP_PACKAGE_TRIGGER_POST)
      UPDATE_INITRAMFS_PACKAGE=$(grep '^UPDATE_INITRAMFS_PACKAGE' $TMP_PACKAGE_TRIGGER_POST | cut -f 2 -d '=' | tr -d '"')

      if [ "$UPDATE_INITRAMFS_PACKAGE" != "" ]; then
        TEXT="The following files failed the verification process AFTER package updates ran:\n${CHANGED_FILES}\n\nThis is likely due to package triggers in$UPDATE_INITRAMFS_PACKAGE.\n\nYou will need to update your checksums for all files in /boot.\n\nWould you like to update your checksums now?"
      else
        TEXT="The following files failed the verification process AFTER package updates ran:\n${CHANGED_FILES}\n\nThis might be due to the following package updates:\n$LAST_PACKAGE_LIST.\n\nYou will need to update your checksums for all files in /boot.\n\nWould you like to update your checksums now?"
      fi

    else
      TEXT="The following files failed the verification process:\n\n${CHANGED_FILES}\n\nThis could indicate a compromise!\n\nWould you like to update your checksums now?"
    fi

    if (whiptail $BG_COLOR_ERROR --clear --title 'ERROR: Boot Hash Mismatch' --yesno "$TEXT" 30 90) then
      update_checksums
    fi
    return 1
  fi
}
prompt_update_checksums()
{
  if (whiptail --title 'Update Checksums and sign all files in /boot' \
      --yesno "You have chosen to update the checksums and sign all of the files in /boot.\n\nThis means that you trust that these files have not been tampered with.\n\nYou will need your GPG key available, and this change will modify your disk.\n\nDo you want to continue?" 16 90) then
    update_checksums
  else
    echo "Returning to the main menu"
  fi
}
update_totp()
{
  echo "Scan the QR code to add the new TOTP secret"
  /bin/seal-totp
  if [ -x /bin/hotp_verification ]; then
    echo "Once you have scanned the QR code, hit Enter to configure your HOTP USB Security Dongle (e.g. Librem Key or Nitrokey)"
    read
    /bin/seal-hotpkey
  else
    echo "Once you have scanned the QR code, hit Enter to continue"
    read
  fi
}

clean_boot_check()
{
  # assume /boot mounted
  if ! grep -q /boot /proc/mounts ; then
    return
  fi

  # check for any kexec files in /boot
  kexec_files=`find /boot -name kexec*.txt`
  [ ! -z "$kexec_files" ] && return

  #check for GPG key in keyring
  GPG_KEY_COUNT=`gpg -k 2>/dev/null | wc -l`
  [ $GPG_KEY_COUNT -ne 0 ] && return

   # check for USB security token
  if [ "$CONFIG_HOTPKEY" = "y" ]; then
    enable_usb
    if ! gpg --card-status > /dev/null ; then
      return
    fi
  fi

  # OS is installed, no kexec files present, no GPG keys in keyring, security token present
  # prompt user to run OEM factory reset
  oem-factory-reset \
    "Clean Boot Detected - Perform OEM Factory Reset?" "$BG_COLOR_WARNING"
}

if detect_boot_device ; then
  # /boot device with installed OS found
  clean_boot_check
else
  # can't determine /boot device or no OS installed,
  # so fall back to interactive selection
  mount_boot
fi

# Use stored HOTP key branding
if [ -r /boot/kexec_hotp_key ]; then
	HOTPKEY_BRANDING="$(cat /boot/kexec_hotp_key)"
else
	HOTPKEY_BRANDING="HOTP USB Security Dongle"
fi

last_half=X
while true; do
  MAIN_MENU_OPTIONS=""
  MAIN_MENU_BG_COLOR=""
  unset totp_confirm
  # detect whether any GPG keys exist in the keyring, if not, initialize that first
  GPG_KEY_COUNT=`gpg -k 2>/dev/null | wc -l`
  if [ $GPG_KEY_COUNT -eq 0 ]; then
    whiptail $BG_COLOR_ERROR --clear --title "ERROR: GPG keyring empty!" \
      --menu "ERROR: Heads couldn't find any GPG keys in your keyring.\n\nIf this is the first time the system has booted,\nyou should add a public GPG key to the BIOS now.\n\nIf you just reflashed a new BIOS, you'll need to add at least one\npublic key to the keyring.\n\nIf you have not just reflashed your BIOS, THIS COULD INDICATE TAMPERING!\n\nHow would you like to proceed?" 30 90 4 \
      'G' ' Add a GPG key to the running BIOS' \
      'i' ' Ignore error and continue to main menu' \
      'x' ' Exit to recovery shell' \
      2>/tmp/whiptail || recovery "GUI menu failed"

      totp_confirm=$(cat /tmp/whiptail)
  fi
  if [ "$totp_confirm" = "i" -o -z "$totp_confirm" ]; then
    # update the TOTP code every thirty seconds
    date=`date "+%Y-%m-%d %H:%M:%S"`
    seconds=`date "+%s"`
    half=`expr \( $seconds % 60 \) / 30`
    if [ "$CONFIG_TPM" = n ]; then
      TOTP="NO TPM"
    elif [ "$half" != "$last_half" ]; then
      last_half=$half;
      TOTP=`unseal-totp`
      if [ $? -ne 0 ]; then
        whiptail $BG_COLOR_ERROR --clear --title "ERROR: TOTP Generation Failed!" \
          --menu "    ERROR: Heads couldn't generate the TOTP code.\n
    If you have just completed a Factory Reset, or just reflashed
    your BIOS, you should generate a new HOTP/TOTP secret.\n
    If this is the first time the system has booted, you should
    reset the TPM and set your own password.\n
    If you have not just reflashed your BIOS, THIS COULD INDICATE TAMPERING!\n
    How would you like to proceed?" 30 90 4 \
          'g' ' Generate new HOTP/TOTP secret' \
          'i' ' Ignore error and continue to main menu' \
          'p' ' Reset the TPM' \
          'x' ' Exit to recovery shell' \
          2>/tmp/whiptail || recovery "GUI menu failed"

        totp_confirm=$(cat /tmp/whiptail)
      fi
    fi
  fi

  if [ "$totp_confirm" = "i" -o -z "$totp_confirm" ]; then
    if [ -x /bin/hotp_verification ]; then
      HOTP=`unseal-hotp`
      enable_usb
      if ! hotp_verification info ; then
        whiptail $BG_COLOR_WARNING --clear \
	--title "WARNING: Please Insert Your $HOTPKEY_BRANDING" \
	--msgbox "Your $HOTPKEY_BRANDING was not detected.\n\nPlease insert your $HOTPKEY_BRANDING" 30 90
        fi
      # Don't output HOTP codes to screen, so as to make replay attacks harder
      hotp_verification check $HOTP
      case "$?" in
        0 )
          HOTP="Success"
        ;;
        4 )
          HOTP="Invalid code"
          MAIN_MENU_BG_COLOR=$BG_COLOR_ERROR
        ;;
        * )
          HOTP="Error checking code, Insert $HOTPKEY_BRANDING and retry"
          MAIN_MENU_BG_COLOR=$BG_COLOR_WARNING
        ;;
      esac
    else
      HOTP='N/A'
    fi

    whiptail $MAIN_MENU_BG_COLOR --clear --title "$MAIN_MENU_TITLE" \
      --menu "$date\nTOTP: $TOTP | HOTP: $HOTP" 20 90 10 \
      'y' ' Default boot' \
      'r' ' Refresh TOTP/HOTP' \
      'a' ' Options -->' \
      'S' ' System Info' \
      'P' ' Power Off' \
      2>/tmp/whiptail || recovery "GUI menu failed"

    totp_confirm=$(cat /tmp/whiptail)
  fi

  if [ "$totp_confirm" = "a" ]; then
    whiptail --clear --title "HEADS Options" \
      --menu "" 20 90 10 \
      'o' ' Boot Options -->' \
      't' ' TPM/TOTP/HOTP Options -->' \
      's' ' Update checksums and sign all files in /boot' \
      'c' ' Change configuration settings -->' \
      'f' ' Flash/Update the BIOS -->' \
      'G' ' GPG Options -->' \
      'F' ' OEM Factory Reset -->' \
      'x' ' Exit to recovery shell' \
      'r' ' <-- Return to main menu' \
      2>/tmp/whiptail || recovery "GUI menu failed"

    totp_confirm=$(cat /tmp/whiptail)
  fi

  if [ "$totp_confirm" = "o" ]; then
    whiptail --clear --title "Boot Options" \
      --menu "Select A Boot Option" 20 90 10 \
      'm' ' Show OS boot menu' \
      'u' ' USB boot' \
      'i' ' Ignore tampering and force a boot (Unsafe!)' \
      'r' ' <-- Return to main menu' \
      2>/tmp/whiptail || recovery "GUI menu failed"

    totp_confirm=$(cat /tmp/whiptail)
  fi

  if [ "$totp_confirm" = "t" ]; then
    whiptail --clear --title "TPM/TOTP/HOTP Options" \
      --menu "Select An Option" 20 90 10 \
      'g' ' Generate new TOTP/HOTP secret' \
      'p' ' Reset the TPM' \
      'n' ' TOTP/HOTP does not match after refresh, troubleshoot' \
      'r' ' <-- Return to main menu' \
      2>/tmp/whiptail || recovery "GUI menu failed"

    totp_confirm=$(cat /tmp/whiptail)
  fi

  if [ "$totp_confirm" = "x" ]; then
    recovery "User requested recovery shell"
  fi

  if [ "$totp_confirm" = "r" ]; then
    continue
  fi

  if [ "$totp_confirm" = "n" ]; then
    if (whiptail $BG_COLOR_WARNING --title "TOTP/HOTP code mismatched" \
      --yesno "TOTP/HOTP code mismatches could indicate either TPM tampering or clock drift:\n\nTo correct clock drift: 'date -s HH:MM:SS'\nand save it to the RTC: 'hwclock -w'\nthen reboot and try again.\n\nWould you like to exit to a recovery console?" 30 90) then
      echo ""
      echo "To correct clock drift: 'date -s HH:MM:SS'"
      echo "and save it to the RTC: 'hwclock -w'"
      echo "then reboot and try again"
      echo ""
      recovery "TOTP/HOTP mismatch"
    else
      continue
    fi
  fi

  if [ "$totp_confirm" = "u" ]; then
    exec /bin/usb-init
    continue
  fi

  if [ "$totp_confirm" = "g" ]; then
    if (whiptail --title 'Generate new TOTP/HOTP secret' \
        --yesno "This will erase your old secret and replace it with a new one!\n\nDo you want to proceed?" 16 90) then
      update_totp
    else
      echo "Returning to the main menu"
    fi
    continue
  fi

  if [ "$totp_confirm" = "p" ]; then
    if [ "$CONFIG_TPM" = "y" ]; then
      if (whiptail --title 'Reset the TPM' \
          --yesno "This will clear the TPM and TPM password, replace them with new ones!\n\nDo you want to proceed?" 16 90) then
        /bin/tpm-reset

        # now that the TPM is reset, remove invalid TPM counter files
        mount_boot
        mount -o rw,remount /boot
        rm -f /boot/kexec_rollback.txt

        # create Heads TPM counter before any others
        check_tpm_counter /boot/kexec_rollback.txt \
        || die "Unable to find/create tpm counter"
        counter="$TPM_COUNTER"

        increment_tpm_counter $counter \
        || die "Unable to increment tpm counter"

        sha256sum /tmp/counter-$counter > /boot/kexec_rollback.txt \
        || die "Unable to create rollback file"
        mount -o ro,remount /boot

        update_totp
      else
        echo "Returning to the main menu"
      fi
    else
      whiptail --clear --title 'ERROR: No TPM Detected' --msgbox "This device does not have a TPM.\n\nPress OK to return to the Main Menu" 30 90
    fi
    continue
  fi

  if [ "$totp_confirm" = "m" ]; then
    # Try to select a kernel from the menu
    mount_boot
    verify_global_hashes
    if [ $? -ne 0 ]; then
      continue
    fi
    kexec-select-boot -m -b /boot -c "grub.cfg" -g
    continue
  fi

  if [ "$totp_confirm" = "i" ]; then
    # Run the menu selection in "force" mode, bypassing hash checks
    if (whiptail $BG_COLOR_WARNING --title 'Unsafe Forced Boot Selected!' \
        --yesno "WARNING: You have chosen to skip all tamper checks and boot anyway.\n\nThis is an unsafe option!\n\nDo you want to proceed?" 16 90) then
      mount_boot
      kexec-select-boot -m -b /boot -c "grub.cfg" -g -f
    else
      echo "Returning to the main menu"
    fi
    continue
  fi

  if [ "$totp_confirm" = "s" ]; then
    prompt_update_checksums
    continue
  fi

  if [ "$totp_confirm" = "c" ]; then
    config-gui.sh
    continue
  fi

  if [ "$totp_confirm" = "f" ]; then
    flash-gui.sh
    continue
  fi

  if [ "$totp_confirm" = "G" ]; then
    gpg-gui.sh
    continue
  fi

  if [ "$totp_confirm" = "S" ]; then
    memtotal=$(grep 'MemTotal' /proc/meminfo | tr -s ' ' | cut -f2 -d ' ')
    memtotal=$((${memtotal} / 1024 / 1024 + 1))
    cpustr=$(grep 'model name' /proc/cpuinfo | uniq | sed -r 's/\(R\)//;s/\(TM\)//;s/CPU //;s/model name.*: //')
    kernel=$(uname -s -r)
		whiptail --title 'System Info' \
      --msgbox "${BOARD_NAME}\n\nFW_VER: ${FW_VER}\nKernel: ${kernel}\n\nCPU: ${cpustr}\nRAM: ${memtotal} GB\n\n$(fdisk -l | grep -e '/dev/sd.:' -e '/dev/nvme.*:' | sed 's/B,.*/B/')" 16 60
    continue
  fi

  if [ "$totp_confirm" = "F" ]; then
    oem-factory-reset
    continue
  fi

  if [ "$totp_confirm" = "P" ]; then
    poweroff
  fi

  if [ "$totp_confirm" = "y" -o -n "$totp_confirm" ]; then
    # Try to boot the default
    mount_boot
    verify_global_hashes
    if [ $? -ne 0 ]; then
      continue
    fi
    DEFAULT_FILE=`find /boot/kexec_default.*.txt 2>/dev/null | head -1`
    if [ -r "$DEFAULT_FILE" ]; then
      kexec-select-boot -b /boot -c "grub.cfg" -g \
      || recovery "Failed default boot"
    else
      if (whiptail --title 'No Default Boot Option Configured' \
          --yesno "There is no default boot option configured yet.\nWould you like to load a menu of boot options?\nOtherwise you will return to the main menu." 16 90) then
        kexec-select-boot -m -b /boot -c "grub.cfg" -g
      else
        echo "Returning to the main menu"
      fi
      continue
    fi
  fi

done

recovery "Something failed during boot"
