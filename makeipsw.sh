#!/usr/bin/env bash
# This is a script to make a ipsw for the apple tv 4k, many thanks to the 14.8.1 script

if [ -z "$1" ] & [ -z "$2" ]; then
    echo "Usage: pathtoota linktotv4ipsw" && exit 1
fi

set -e
#set -o xtrace

mkdir -p ipsws
sudo rm -rf work | true
sudo rm /tmp/BI0.plist | true
#if [ -z "$VOLUME_NAME" ]; then
	VOLUME_NAME=TV_RESTORE_OTA
#fi

# aria2c args
#if [ -z "$3" ]; then
#    aria2c_args="-j32 -x32 -s32"
#else
#    aria2c_args="-j$3 -x$3 -s$3"
#fi

# download the ota
#aria2c $aria2c_args "$1" -o "ota-$2.zip"

# create work dir
mkdir -p work/ota work/ipsw

# unzip ota
cd work/ota
unzip $1

mkdir AssetData/rootfs
cd AssetData/rootfs
find ../payloadv2 -name 'payload.[0-9][0-9][0-9]' -print -exec sudo aa extract -i {} \;
sudo aa extract -i ../payloadv2/fixup.manifest || true
sudo aa extract -i ../payloadv2/data_payload
sudo chown -R 0:0 ../payload/replace/*
sudo cp -a ../payload/replace/* .

#for app in ../payloadv2/app_patches/*.app; do
#    appname=$(echo $app | cut -d/ -f4)
#    sudo mkdir -p "private/var/staged_system_apps/$appname"
#    sudo cp -a "$app" "private/var/staged_system_apps/$appname"
#    pushd "private/var/staged_system_apps/$appname"
#    sudo 7z x "$appname" || true;
#    sudo aa extract -i $(echo "$appname" | cut -d. -f1)|| true;
#    sudo rm "$appname"
#    popd
#done

# make the root dmg
cd ..
cp ../../../template.dmg output.dmg
hdiutil resize -size 10000m output.dmg
sudo hdiutil attach output.dmg -owners on
sudo mount -urw /Volumes/Template
sudo rsync -a rootfs/ /Volumes/Template/
sudo diskutil rename /Volumes/Template $VOLUME_NAME
hdiutil detach /Volumes/$VOLUME_NAME
hdiutil convert -format ULFO -o converted.dmg output.dmg
asr imagescan --source converted.dmg
cd ../..

cd ipsw
cp -r ../ota/AssetData/boot/Firmware .
cp ../ota/AssetData/boot/kernelcache.release.* .

cp ../ota/AssetData/boot/BuildManifest.plist .

/usr/libexec/PlistBuddy -c "Set :BuildIdentities:0:Info:RestoreBehavior Erase" BuildManifest.plist
/usr/libexec/PlistBuddy -c "Set :BuildIdentities:0:Info:Variant Customer Erase Install (IPSW)" BuildManifest.plist
/usr/libexec/PlistBuddy -c "Set :BuildIdentities:0:Manifest:RestoreRamDisk:Info:Path arm64SURamDisk.dmg" BuildManifest.plist
/usr/libexec/PlistBuddy -c "Set :BuildIdentities:0:Manifest:RestoreTrustCache:Info:Path Firmware/arm64SURamDisk.dmg.trustcache" BuildManifest.plist

/usr/libexec/PlistBuddy -x -c "Print :BuildIdentities:0" BuildManifest.plist > /tmp/BI0.plist
/usr/libexec/PlistBuddy -c "Add :BuildIdentities:1 dict" BuildManifest.plist
/usr/libexec/PlistBuddy -x -c "Merge /tmp/BI0.plist :BuildIdentities:1" BuildManifest.plist
sudo rm /tmp/BI0.plist

/usr/libexec/PlistBuddy -c "Set :BuildIdentities:1:Info:RestoreBehavior Update" BuildManifest.plist
/usr/libexec/PlistBuddy -c "Set :BuildIdentities:1:Info:Variant Customer Upgrade Install (IPSW)" BuildManifest.plist
/usr/libexec/PlistBuddy -c "Set :BuildIdentities:1:Manifest:RestoreRamDisk:Info:Path arm64SURamDisk2.dmg" BuildManifest.plist
/usr/libexec/PlistBuddy -c "Set :BuildIdentities:1:Manifest:RestoreTrustCache:Info:Path Firmware/arm64SURamDisk2.dmg.trustcache" BuildManifest.plist

ipsw_rootfs=$(plutil -extract "BuildIdentities".0."Manifest"."OS"."Info"."Path" raw -expect string -o - BuildManifest.plist)

mv ../ota/AssetData/converted.dmg $ipsw_rootfs
cd ..
../Darwin/pzb -g BuildManifest.plist $2
tv4_restoreramdisk=$(plutil -extract "BuildIdentities".0."Manifest"."RestoreRamDisk"."Info"."Path" raw -expect string -o - BuildManifest.plist)
tv4_updateramdisk=$(plutil -extract "BuildIdentities".1."Manifest"."RestoreRamDisk"."Info"."Path" raw -expect string -o - BuildManifest.plist)
rm BuildManifest.plist
../Darwin/pzb -g $tv4_restoreramdisk $2
../Darwin/pzb -g $tv4_updateramdisk $2
mv $tv4_restoreramdisk ipsw/arm64SURamDisk.dmg
mv $tv4_updateramdisk ipsw/arm64SURamDisk2.dmg
cd ipsw

# Patch the Restore/Update ramdisk
for identity in $(eval echo {0..$(expr $(plutil -extract BuildIdentities raw -expect array -o - BuildManifest.plist) - 1)}); do
	ipsw_restoreramdisk=$(plutil -extract "BuildIdentities".${identity}."Manifest"."RestoreRamDisk"."Info"."Path" raw -expect string -o - BuildManifest.plist)
	ipsw_restorebehavior=$(plutil -extract "BuildIdentities".${identity}."Info"."RestoreBehavior" raw -expect string -o - BuildManifest.plist)
	case $ipsw_restorebehavior in
		Erase)
		restored_suffix="_external"
		;;
		Update)
		restored_suffix="_update"
		;;
		*)
		>&2 echo "Unknown RestoreBehavior: ${ipsw_restorebehavior}"
		exit 1;
		;;
	esac

	if [ -f "${ipsw_restoreramdisk}.rdsk-done" ]; then continue; fi
    ../../Darwin/img4 -i $ipsw_restoreramdisk -o decrypted.dmg

	restoreramdisk_mount_path=$(hdiutil attach decrypted.dmg -owners on | awk 'END {print $NF}' | tr -d '\n')
	sudo mount -urw "$restoreramdisk_mount_path"
	sudo ../../Darwin/asr64_patcher "$restoreramdisk_mount_path"/usr/sbin/asr{,.patched}
	sudo mv "$restoreramdisk_mount_path"/usr/sbin/asr{.patched,}
	sudo ../../Darwin/restored_external64_patcher "$restoreramdisk_mount_path"/usr/local/bin/restored${restored_suffix}{,.patched}
	sudo mv "$restoreramdisk_mount_path"/usr/local/bin/restored${restored_suffix}{.patched,}
	sudo ../../Darwin/ldid -s "$restoreramdisk_mount_path"/usr/local/bin/restored${restored_suffix} "$restoreramdisk_mount_path"/usr/sbin/asr
	sudo chmod 755 "$restoreramdisk_mount_path"/usr/local/bin/restored${restored_suffix} "$restoreramdisk_mount_path"/usr/sbin/asr

	ipsw_restoretrustcache=$(plutil -extract "BuildIdentities".${identity}."Manifest"."RestoreTrustCache"."Info"."Path" raw -expect string -o - BuildManifest.plist)
    ../../Darwin/trustcache create -v 1 ${ipsw_restoretrustcache}.dec "$restoreramdisk_mount_path"
	hdiutil detach "${restoreramdisk_mount_path}"

    ../../Darwin/img4 -i decrypted.dmg -o $ipsw_restoreramdisk -A -T rdsk
    ../../Darwin/img4 -i ${ipsw_restoretrustcache}.dec -o ${ipsw_restoretrustcache} -A -T rtsc
	rm -f ${ipsw_restoretrustcache}.dec decrypted.dmg
	touch "${ipsw_restoreramdisk}.rdsk-done"
done

rm -f *".rdsk-done"
# make the ipsw
ipsw_buildnumber=$(plutil -extract "ProductBuildVersion" raw -expect string -o - BuildManifest.plist)
ipsw_version=$(plutil -extract "ProductVersion" raw -expect string -o - BuildManifest.plist)
rm ../../ipsws/AppleTV6,2_"$ipsw_version"_"$ipsw_buildnumber"_Restore.ipsw | true
zip -r9 ../../ipsws/AppleTV6,2_"$ipsw_version"_"$ipsw_buildnumber"_Restore.ipsw . -x "*.DS_Store"
cd ../../
sudo rm -rf work | true

echo "Done! Your new ipsw is in ipsws/AppleTV6,2_${ipsw_version}_${ipsw_buildnumber}_Restore.ipsw"
echo "Please use my fork of futurerestore to restore in pwned dfu mode, manually specifying the sep, from here: https://github.com/verygenericname/futurerestore/actions"
