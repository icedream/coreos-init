#!/bin/sh -e

script="./prepare.sh"

losetup_device=""

test_disk_file="./test/disk"
test_disk_size=8G

cleanup() {
	if [ -n "$losetup_device" ]
	then
		sudo losetup -d "$losetup_device" || true
	fi
	if [ -n "$test_disk_file" ]
	then
		rm -f "$test_disk_file"
	fi
}
trap cleanup EXIT

truncate -s "$test_disk_size" "$test_disk_file"

losetup_device="$(sudo losetup --show -P -L -f "$test_disk_file")"
echo "Our test device is: $losetup_device" >&2

sh -ex "${script}" \
	--system-disk "$losetup_device"
