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

if ! pmex path "$PKG_NAME" >&2; then
	if pmex install-existing "$PKG_NAME" >&2; then
		pmex uninstall-system-updates "$PKG_NAME"
	fi
fi

IS_SYS=false
INS=true
if BASEPATH=$(pmex path "$PKG_NAME"); then
	echo >&2 "'$BASEPATH'"
	BASEPATH=${BASEPATH##*:} BASEPATH=${BASEPATH%/*}
	if [ "${BASEPATH:1:4}" != data ]; then
		ui_print "* $PKG_NAME is a system app."
		IS_SYS=true
	elif [ ! -f "$MODPATH/$PKG_NAME.apk" ]; then
		ui_print "* Stock $PKG_NAME APK was not found"
		VERSION=$(dumpsys package "$PKG_NAME" 2>&1 | grep -m1 versionName) VERSION="${VERSION#*=}"
		if [ "$VERSION" = "$PKG_VER" ] || [ -z "$VERSION" ]; then
			ui_print "* Skipping stock installation"
			INS=false
		else
			abort "ERROR: Version mismatch
			installed: $VERSION
			module:    $PKG_VER
			"
		fi
	elif "${MODPATH:?}/bin/$ARCH/cmpr" "$BASEPATH/base.apk" "$MODPATH/$PKG_NAME.apk"; then
		ui_print "* $PKG_NAME is up-to-date"
		INS=false
	fi
fi

install() {
	if [ ! -f "$MODPATH/$PKG_NAME.apk" ]; then
		abort "ERROR: Stock $PKG_NAME apk was not found"
	fi
	ui_print "* Updating $PKG_NAME to $PKG_VER"
	install_err=""
	VERIF1=$(settings get global verifier_verify_adb_installs)
	VERIF2=$(settings get global package_verifier_enable)
	settings put global verifier_verify_adb_installs 0
	settings put global package_verifier_enable 0
	SZ=$(stat -c "%s" "$MODPATH/$PKG_NAME.apk")
	for IT in 1 2; do
		if ! SES=$(pmex install-create --user 0 -i com.android.vending -r -g -d -S "$SZ"); then
			ui_print "ERROR: install-create failed"
			install_err="$SES"
			break
		fi
		SES=${SES#*[} SES=${SES%]*}
		set_perm "$MODPATH/$PKG_NAME.apk" 1000 1000 644 u:object_r:apk_data_file:s0
		if ! op=$(pmex install-write -S "$SZ" "$SES" "$PKG_NAME.apk" "$MODPATH/$PKG_NAME.apk"); then
			ui_print "ERROR: install-write failed"
			install_err="$op"
			break
		fi
		if ! op=$(pmex install-commit "$SES"); then
			echo >&2 "$op"
			if echo "$op" | grep -q -e INSTALL_FAILED_VERSION_DOWNGRADE -e INSTALL_FAILED_UPDATE_INCOMPATIBLE; then
				ui_print "* Handling install error"
				pmex uninstall-system-updates "$PKG_NAME"
				BASEPATH=$(pmex path "$PKG_NAME") || abort
				BASEPATH=${BASEPATH##*:} BASEPATH=${BASEPATH%/*}
				if [ "${BASEPATH:1:4}" != data ]; then IS_SYS=true; fi
				if [ "$IS_SYS" = true ]; then
					SCNM="/data/adb/post-fs-data.d/$PKG_NAME-uninstall.sh"
					if [ -f "$SCNM" ]; then
						ui_print "* Remove the old module. Reboot and reflash!"
						ui_print ""
						install_err=" "
						break
					fi
					mkdir -p /data/adb/rvhc/empty /data/adb/post-fs-data.d
					echo "mount -o bind /data/adb/rvhc/empty $BASEPATH" >"$SCNM"
					chmod +x "$SCNM"
					ui_print "* Created the uninstall script."
					ui_print ""
					ui_print "* Reboot and reflash the module!"
					install_err=" "
					break
				else
					ui_print "* Uninstalling..."
					if ! op=$(pmex uninstall -k --user 0 "$PKG_NAME"); then
						ui_print "$op"
						if [ $IT = 2 ]; then
							install_err="ERROR: pm uninstall failed."
							break
						fi
					fi
					continue
				fi
			fi
			ui_print "ERROR: install-commit failed"
			install_err="$op"
			break
		fi
		if BASEPATH=$(pmex path "$PKG_NAME"); then
			BASEPATH=${BASEPATH##*:} BASEPATH=${BASEPATH%/*}
		else
			install_err="ERROR: install $PKG_NAME manually and reflash the module"
			break
		fi
		break
	done
	settings put global verifier_verify_adb_installs "$VERIF1"
	settings put global package_verifier_enable "$VERIF2"
	if [ "$install_err" ]; then abort "$install_err"; fi
}
if [ $INS = true ] && ! install; then abort; fi
BASEPATHLIB=${BASEPATH}/lib/${ARCH}
if [ $INS = true ] || [ -z "$(ls -A1 "$BASEPATHLIB")" ]; then
	ui_print "* Extracting native libs"
	if [ ! -d "$BASEPATHLIB" ]; then mkdir -p "$BASEPATHLIB"; else rm -f "$BASEPATHLIB"/* >/dev/null 2>&1 || :; fi
	if ! op=$(unzip -o -j "$MODPATH/$PKG_NAME.apk" "lib/${ARCH_LIB}/*" -d "$BASEPATHLIB" 2>&1); then
		ui_print "ERROR: extracting native libs failed"
		abort "$op"
	fi
	set_perm_recursive "${BASEPATH}/lib" 1000 1000 755 755 u:object_r:apk_data_file:s0
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

cmd package compile -m speed-profile -f "$PKG_NAME"
# nohup cmd package compile -m speed-profile -f "$PKG_NAME" >/dev/null 2>&1
cmd appops set com.google.android.youtube RUN_IN_BACKGROUND ignore
cmd appops set com.google.android.youtube RUN_ANY_IN_BACKGROUND ignore

if [ "$KSU" ]; then
	UID=$(dumpsys package "$PKG_NAME" 2>&1 | grep -m1 uid)
	UID=${UID#*=} UID=${UID%% *}
	if [ -z "$UID" ]; then
		UID=$(dumpsys package "$PKG_NAME" 2>&1 | grep -m1 userId)
		UID=${UID#*=} UID=${UID%% *}
	fi
	if [ "$UID" ]; then
		if ! OP=$("${MODPATH:?}/bin/$ARCH/ksu_profile" "$UID" "$PKG_NAME" 2>&1); then
			ui_print "ERROR ksu_profile: $OP"
		fi
	else
		ui_print "ERROR: UID could not be found for $PKG_NAME"
		dumpsys package "$PKG_NAME" >&2
	fi
fi

configyt() {		
# config
echo "ImF1dG9fY2FwdGlvbnNfc3R5bGUiOiAiYm90aF9kaXNhYmxlZCIsCiJieXBhc3NfYW1iaWVudF9tb2RlX3Jlc3RyaWN0aW9ucyI6IHRydWUsCiJieXBhc3NfaW1hZ2VfcmVnaW9uX3Jlc3RyaWN0aW9ucyI6IHRydWUsCiJjb3B5X3ZpZGVvX3VybF90aW1lc3RhbXAiOiBmYWxzZSwKImdyYWRpZW50X2xvYWRpbmdfc2NyZWVuIjogdHJ1ZSwKImhpZGVfYXV0b3BsYXlfYnV0dG9uIjogZmFsc2UsCiJoaWRlX2Nhc3RfYnV0dG9uIjogZmFsc2UsCiJoaWRlX2NvbW1lbnRzX2NyZWF0ZV9hX3Nob3J0X2J1dHRvbiI6IGZhbHNlLAoiaGlkZV9jb21tdW5pdHlfYnV0dG9uIjogZmFsc2UsCiJoaWRlX2Nyb3dkZnVuZGluZ19ib3giOiB0cnVlLAoiaGlkZV9mbG9hdGluZ19taWNyb3Bob25lX2J1dHRvbiI6IGZhbHNlLAoiaGlkZV9ob3Jpem9udGFsX3NoZWx2ZXMiOiBmYWxzZSwKImhpZGVfaW1hZ2Vfc2hlbGYiOiBmYWxzZSwKImhpZGVfbGF0ZXN0X3Bvc3RzIjogZmFsc2UsCiJoaWRlX3BsYXlhYmxlcyI6IGZhbHNlLAoiaGlkZV9wcmVtaXVtX3ZpZGVvX3F1YWxpdHkiOiBmYWxzZSwKImhpZGVfc2hvcnRzX2J1dHRvbiI6IGZhbHNlLAoiaGlkZV9zaG9ydHNfZWZmZWN0X2J1dHRvbiI6IGZhbHNlLAoiaGlkZV9zaG9ydHNfaW5mb19wYW5lbCI6IGZhbHNlLAoiaGlkZV9zaG9ydHNfbmV3X3Bvc3RzX2J1dHRvbiI6IGZhbHNlLAoiaGlkZV9zaG9ydHNfcHJldmlld19jb21tZW50IjogZmFsc2UsCiJoaWRlX3Nob3J0c19zYXZlX3NvdW5kX2J1dHRvbiI6IGZhbHNlLAoiaGlkZV9zaG9ydHNfc2VhcmNoX3N1Z2dlc3Rpb25zIjogZmFsc2UsCiJoaWRlX3Nob3J0c19zdGlja2VycyI6IGZhbHNlLAoiaGlkZV9zaG9ydHNfdXNlX3NvdW5kX2J1dHRvbiI6IGZhbHNlLAoiaGlkZV9zaG9ydHNfdXNlX3RlbXBsYXRlX2J1dHRvbiI6IGZhbHNlLAoiaGlkZV9zaG93X21vcmVfYnV0dG9uIjogZmFsc2UsCiJoaWRlX3RpbWVkX3JlYWN0aW9ucyI6IGZhbHNlLAoiaGlkZV90b29sYmFyX2NyZWF0ZV9idXR0b24iOiBmYWxzZSwKImhpZGVfdmlkZW9fcmVjb21tZW5kYXRpb25fbGFiZWxzIjogZmFsc2UsCiJoaWRlX3dlYl9zZWFyY2hfcmVzdWx0cyI6IGZhbHNlLAoiaGlkZV95b3VfbWF5X2xpa2Vfc2VjdGlvbiI6IGZhbHNlLAoibWluaXBsYXllcl90eXBlIjogIm1vZGVybl8yIiwKIm5hdmlnYXRpb25fYmFyX2FuaW1hdGlvbnMiOiB0cnVlLAoic3Bvb2ZfZGV2aWNlX2RpbWVuc2lvbnMiOiB0cnVlLAoic3dhcF9jcmVhdGVfd2l0aF9ub3RpZmljYXRpb25zX2J1dHRvbiI6IGZhbHNlLAoidmlkZW9fcXVhbGl0eV9kZWZhdWx0X21vYmlsZSI6IDM2MCwKInZpZGVvX3F1YWxpdHlfZGVmYXVsdF93aWZpIjogNzIw" | base64 -d > "$YTC/YouTube-V$PKG_VER.txt"
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

rm -rf "${MODPATH:?}/bin" "$MODPATH/$PKG_NAME.apk"

ui_print "* Done"
ui_print "  by j-hc (github.com/j-hc)"
ui_print "  remod by hafizd"
ui_print " "
