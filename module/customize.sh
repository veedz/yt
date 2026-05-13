. "$MODPATH/config"
RVAPPVER="$(grep_prop version "$MODPATH/module.prop")"
CACHE=/sdcard/Android/data/com.google.android.youtube
YTC="/sdcard"

case $(getprop ro.build.version.sdk) in
	27|28|29|30|31|32|33)
		rm -rf /data/data/$PKG_NAME/cache
		rm -rf /data/data/$PKG_NAME/code_cache
		;;
	32|33|34|35|36)
		rm -rf /data_mirror/data_ce/null/0/$PKG_NAME/cache
		rm -rf /data_mirror/data_ce/null/0/$PKG_NAME/code_cache
		;;
esac

ui_print ""
if [ -n "$MODULE_ARCH" ] && [ "$MODULE_ARCH" != "$ARCH" ]; then
	abort "ERROR: Wrong arch
Your device: $ARCH
Module: $MODULE_ARCH"
fi
if [ "$ARCH" = "arm" ]; then
	ARCH_LIB=armeabi-v7a
elif [ "$ARCH" = "arm64" ]; then
	ARCH_LIB=arm64-v8a
elif [ "$ARCH" = "x86" ]; then
	ARCH_LIB=x86
elif [ "$ARCH" = "x64" ]; then
	ARCH_LIB=x86_64
else abort "ERROR: unreachable: ${ARCH}"; fi
RVPATH=/data/adb/rvhc/${MODPATH##*/}.apk

set_perm_recursive "$MODPATH/bin" 0 0 0755 0777

if su -M -c true >/dev/null 2>/dev/null; then
	alias mm='su -M -c'
else alias mm='nsenter -t1 -m'; fi

mm grep -F "$PKG_NAME" /proc/mounts | while read -r line; do
	ui_print "* Un-mount"
	mp=${line#* } mp=${mp%% *}
	mm umount -l "${mp%%\\*}"
done
am force-stop "$PKG_NAME"

pmex() {
	OP=$(pm "$@" 2>&1 </dev/null)
	RET=$?
	echo "$OP"
	return $RET
}

if OP=$(dumpsys package "$PKG_NAME") && [ "$OP" ]; then
	if echo "$OP" | grep -m1 pkgFlags | grep -Fq UPDATED_SYSTEM_APP; then
		pmex uninstall-system-updates "$PKG_NAME" >/dev/null 2>&1
	fi
else
	if pmex install-existing "$PKG_NAME" >/dev/null 2>&1; then
		pmex uninstall-system-updates "$PKG_NAME" >/dev/null 2>&1
	fi
fi

INS=true
if BASEPATH=$(pmex path "$PKG_NAME"); then
	echo >&2 "'$BASEPATH'"
	BASEPATH=${BASEPATH##*:} BASEPATH=${BASEPATH%/*}
	if [ "${BASEPATH:1:4}" != data ]; then
		ui_print "* Detected $PKG_NAME as a system app"
		SCNM="/data/adb/post-fs-data.d/$PKG_NAME-uninstall.sh"
		mkdir -p /data/adb/post-fs-data.d
		echo "mount -t tmpfs none $BASEPATH" >"$SCNM"
		chmod +x "$SCNM"
		ui_print "* Created the uninstall script."
		ui_print ""
		ui_print "* Reboot and reflash the module!"
		abort
	fi

	VERSION=$(dumpsys package "$PKG_NAME" 2>&1 | grep -m1 versionName=) VERSION="${VERSION#*=}"
	if [ "$VERSION" ] && [ "$VERSION" = "$PKG_VER" ]; then
		ui_print "* $PKG_NAME is up-to-date ($VERSION)"
		INS=false
	elif [ ! -f "$MODPATH/stock/base.apk" ]; then
		ui_print "ERROR: Version mismatch
			installed: '$VERSION'
			module:    '$PKG_VER'"
		abort
	fi

	# TODO:
	# elif "${MODPATH:?}/bin/$ARCH/cmpr" "$BASEPATH/base.apk" "$MODPATH/$PKG_NAME.apk"; then
	# 	ui_print "* $PKG_NAME is up-to-date"
	# 	INS=false
	# fi
fi

install() {
	if [ ! -f "$MODPATH/stock/base.apk" ]; then
		abort "ERROR: Stock $PKG_NAME apk was not found"
	fi
	install_err=""
	VERIF1=$(settings get global verifier_verify_adb_installs)
	VERIF2=$(settings get global package_verifier_enable)
	settings put global verifier_verify_adb_installs 0
	settings put global package_verifier_enable 0

	SZ=$(stat -c "%s" "$MODPATH"/stock/*.apk | awk '{sum += $0} END {print sum}')
	for IT in 1 2; do
		ui_print "* Updating $PKG_NAME to $PKG_VER"
		if ! SES=$(pmex install-create --user 0 -i com.android.vending -r -d -g -S "$SZ"); then
			ui_print "ERROR: install-create failed"
			install_err="$SES"
			break
		fi
		SES=${SES#*[} SES=${SES%]*}

		for apki in "$MODPATH/stock"/*.apk; do
			set_perm "${apki}" 1000 1000 644 u:object_r:apk_data_file:s0
			if ! op=$(pmex install-write -S "$SZ" "$SES" "$(basename "${apki}")" "${apki}"); then
				ui_print "ERROR: install-write failed"
				install_err="$op"
				break
			fi
		done
		if [ "$install_err" ]; then break; fi

		if ! op=$(pmex install-commit "$SES"); then
			ui_print "$op"
			if echo "$op" | grep -q -e INSTALL_FAILED_VERSION_DOWNGRADE -e INSTALL_FAILED_UPDATE_INCOMPATIBLE; then
				ui_print "* Uninstalling..."
				if ! op=$(pmex uninstall "$PKG_NAME"); then
					ui_print "$op"
					if [ $IT = 2 ]; then
						install_err="ERROR: pm uninstall failed."
						break
					fi
				fi
				continue
			fi
			ui_print "ERROR: install-commit failed"
			install_err="$op"
			break
		fi
		if BASEPATH=$(pmex path "$PKG_NAME"); then
			BASEPATH=${BASEPATH##*:} BASEPATH=${BASEPATH%/*}
		else
			install_err=" "
			break
		fi
		break
	done
	settings put global verifier_verify_adb_installs "$VERIF1"
	settings put global package_verifier_enable "$VERIF2"
	if [ "$install_err" ]; then
		abort "$install_err"
	fi
}
if [ $INS = true ] && ! install; then abort; fi
BASEPATHLIB=${BASEPATH}/lib/${ARCH}
if [ $INS = true ] || [ -z "$(ls -A1 "$BASEPATHLIB")" ]; then
	ui_print "* Extracting native libs"
	if [ ! -d "$BASEPATHLIB" ]; then mkdir -p "$BASEPATHLIB"; else rm -f "$BASEPATHLIB"/* >/dev/null 2>&1 || :; fi
	if op=$(unzip -o -j "$MODPATH/stock/base.apk" "lib/${ARCH_LIB}/*" -d "$BASEPATHLIB" 2>&1); then
		set_perm_recursive "${BASEPATH}/lib" 1000 1000 755 755 u:object_r:apk_data_file:s0
	else
		echo >&2 "ERROR: extracting native libs failed: '$op'"
	fi
fi

ui_print "* Setting Permissions"
set_perm "$MODPATH/base.apk" 1000 1000 644 u:object_r:apk_data_file:s0

ui_print "* Mounting $PKG_NAME"
mkdir -p "/data/adb/rvhc"
RVPATH=/data/adb/rvhc/${MODPATH##*/}.apk
mv -f "$MODPATH/base.apk" "$RVPATH"

if ! op=$(mm mount -o bind "$RVPATH" "$BASEPATH/base.apk" 2>&1); then
	ui_print "ERROR: Mount failed!"
	ui_print "$op"
fi
am force-stop "$PKG_NAME"
ui_print "* Optimizing $PKG_NAME"

# cmd package compile -m speed-profile -f "$PKG_NAME" >/dev/null 2>&1
# nohup cmd package compile -m speed-profile -f "$PKG_NAME" >/dev/null 2>&1
cmd appops set com.google.android.youtube RUN_IN_BACKGROUND ignore
cmd appops set com.google.android.youtube RUN_ANY_IN_BACKGROUND ignore

if [ "$KSU" ]; then
	UID=$(dumpsys package "$PKG_NAME" 2>&1 | grep -m1 uid=)
	UID=${UID#*=} UID=${UID%% *}
	if [ -z "$UID" ]; then
		UID=$(dumpsys package "$PKG_NAME" 2>&1 | grep -m1 userId=)
		UID=${UID#*=} UID=${UID%% *}
	fi
	if [ "$UID" ]; then
		if ! OP=$("${MODPATH:?}/bin/$ARCH/ksu_profile" "$UID" "$PKG_NAME" 2>&1); then
			ui_print "  $OP"
			ui_print "* Because you are using a fork of KernelSU, "
			ui_print "  you need to go to your root manager app and"
			ui_print "  disable 'Unmount modules' for $PKG_NAME"
		fi
	else
		ui_print "ERROR: UID could not be found for $PKG_NAME"
	fi
fi

configyt() {		
# config
echo "ImF1dG9fY2FwdGlvbnNfc3R5bGUiOiAid2l0aF92b2x1bWVfb25seSIsCiJieXBhc3NfYW1iaWVudF9tb2RlX3Jlc3RyaWN0aW9ucyI6IHRydWUsCiJieXBhc3NfaW1hZ2VfcmVnaW9uX3Jlc3RyaWN0aW9ucyI6IHRydWUsCiJjb3B5X3ZpZGVvX3VybF9idXR0b25fdGltZXN0YW1wIjogZmFsc2UsCiJncmFkaWVudF9sb2FkaW5nX3NjcmVlbiI6IHRydWUsCiJoaWRlX2F1dG9wbGF5X2J1dHRvbiI6IGZhbHNlLAoiaGlkZV9jYXN0X2J1dHRvbiI6IGZhbHNlLAoiaGlkZV9jb21tZW50c19jcmVhdGVfYV9zaG9ydF9idXR0b24iOiBmYWxzZSwKImhpZGVfY29tbXVuaXR5X2J1dHRvbiI6IGZhbHNlLAoiaGlkZV9jcm93ZGZ1bmRpbmdfYm94IjogdHJ1ZSwKImhpZGVfZmxvYXRpbmdfbWljcm9waG9uZV9idXR0b24iOiBmYWxzZSwKImhpZGVfaG9yaXpvbnRhbF9zaGVsdmVzIjogZmFsc2UsCiJoaWRlX2ltYWdlX3NoZWxmIjogZmFsc2UsCiJoaWRlX2xpbmtzX3ByZXZpZXciOiBmYWxzZSwKImhpZGVfbW92aWVzX3NlY3Rpb24iOiBmYWxzZSwKImhpZGVfcGxheWFibGVzIjogZmFsc2UsCiJoaWRlX3ByZW1pdW1fdmlkZW9fcXVhbGl0eSI6IGZhbHNlLAoiaGlkZV9zaG9ydHNfZWZmZWN0X2J1dHRvbiI6IGZhbHNlLAoiaGlkZV9zaG9ydHNfZ3JlZW5fc2NyZWVuX2J1dHRvbiI6IGZhbHNlLAoiaGlkZV9zaG9ydHNfaGFzaHRhZ19idXR0b24iOiBmYWxzZSwKImhpZGVfc2hvcnRzX2luZm9fcGFuZWwiOiBmYWxzZSwKImhpZGVfc2hvcnRzX25ld19wb3N0c19idXR0b24iOiBmYWxzZSwKImhpZGVfc2hvcnRzX3ByZXZpZXdfY29tbWVudCI6IGZhbHNlLAoiaGlkZV9zaG9ydHNfcmVtaXhfYnV0dG9uIjogZmFsc2UsCiJoaWRlX3Nob3J0c19zYXZlX3NvdW5kX2J1dHRvbiI6IGZhbHNlLAoiaGlkZV9zaG9ydHNfc2VhcmNoX3N1Z2dlc3Rpb25zIjogZmFsc2UsCiJoaWRlX3Nob3J0c191cGNvbWluZ19idXR0b24iOiBmYWxzZSwKImhpZGVfc2hvcnRzX3VzZV9zb3VuZF9idXR0b24iOiBmYWxzZSwKImhpZGVfc2hvcnRzX3VzZV90ZW1wbGF0ZV9idXR0b24iOiBmYWxzZSwKImhpZGVfc2hvd19tb3JlX2J1dHRvbiI6IGZhbHNlLAoiaGlkZV90aW1lZF9yZWFjdGlvbnMiOiBmYWxzZSwKImhpZGVfdG9vbGJhcl9jYXN0X2J1dHRvbiI6IGZhbHNlLAoiaGlkZV92aWRlb19yZWNvbW1lbmRhdGlvbl9sYWJlbHMiOiBmYWxzZSwKImhpZGVfd2ViX3NlYXJjaF9yZXN1bHRzIjogZmFsc2UsCiJoaWRlX3lvdV9tYXlfbGlrZV9zZWN0aW9uIjogZmFsc2UsCiJoaWRlX3lvdXR1YmVfZG9vZGxlcyI6IGZhbHNlLAoibWluaXBsYXllcl90eXBlIjogIm1vZGVybl8yIiwKIm5hdmlnYXRpb25fYmFyX2FuaW1hdGlvbnMiOiB0cnVlLAoic2hvd190b29sYmFyX3NldHRpbmdzX2J1dHRvbiI6IHRydWUsCiJzcG9vZl9kZXZpY2VfZGltZW5zaW9ucyI6IHRydWUsCiJzd2FwX2NyZWF0ZV93aXRoX25vdGlmaWNhdGlvbnNfYnV0dG9uIjogZmFsc2UsCiJ2aWRlb19xdWFsaXR5X2RlZmF1bHRfbW9iaWxlIjogMzYwLAoidmlkZW9fcXVhbGl0eV9kZWZhdWx0X3dpZmkiOiA3MjAs" | base64 -d > "$YTC/YouTube-V$PKG_VER.txt"
}

if [ "$CACHE" ]; then
  rm -rf $CACHE/cache
  mkdir -p $CACHE
  touch $CACHE/cache
fi

if [ "$YTC" ]; then
  rm -rf $YTC/YouTube*.txt $YTC/YouTube*.json
configyt
fi

rm -rf "${MODPATH:?}/bin" "$MODPATH/stock/"

ui_print "* Done"
ui_print "  by j-hc (github.com/j-hc)"
ui_print "  remod by hafizd"
ui_print " "
