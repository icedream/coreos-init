#!/bin/sh -e

script_dir="$(readlink -f .)"
app_dir="$script_dir/app"
gpg_keyring="$app_dir/gnupg/trustedkeys.gpg"

check_file() {
	filename="$1"
	checksum_type="$2"
	checksum="$3"
	case "$checksum_type" in
	md5)
		echo "$checksum $filename" | md5sum -c >/dev/null
		;;
	sha1)
		echo "$checksum $filename" | sha1sum -c >/dev/null
		;;
	sha256)
		echo "$checksum $filename" | sha256sum -c >/dev/null
		;;
	sha512)
		echo "$checksum $filename" | sha512sum -c >/dev/null
		;;
	gpg)
		gpg --verify "$filename" "${checksum:-${filename}.gpg}"
		;;
	*)
		echo "WARNING: Unknown checksum type $checksum_type, defaulting to SHA512." >&1
		echo "$checksum $filename" | sha512sum -c >/dev/null
		;;
	esac
}

download() {
	url="$1"
	checksum_type="$2"
	checksum="$3"
	filename="${4:-$(basename "$url")}"

	# File already downloaded?
	if [ -f "$filename" ] && check_file "$filename" "$checksum_type" "$checksum"
	then
		return 0
	fi

	wget -O"$filename" "$url"
	if [ -f "$filename" ] && ! check_file "$filename" "$checksum_type" "$checksum"
	then
		echo "ERROR: checksum mismatch for $filename (expected to be $checksum_type $checksum). Can not continue." >&2
		return 1
	fi

	return 0
}

clone() {
	url="$1"
	ref="$2"
	target="${3:-$(basename "$(basename "$url")" .git)}"
	remote="${4:-origin}"

	git init "$target"
	(cd "$target"
		if ! git remote get-url "$remote" 2>/dev/null >/dev/null
		then
			git remote add "$remote" "$url"
		else
			git remote set-url "$remote" "$url"
		fi
		git fetch --all
		git clean -fdx
		git reset --hard
		git checkout "$ref"
	)
}

gpg() {
	command gpg --no-default-keyring --keyring "$gpg_keyring" "$@"
}

gpg_import_key() {
	keyfile="$(mktemp -p /var/tmp XXXXXXXX.asc)"
	download "$1" "$2" "$3" "$keyfile" &&\
	gpg --import "$keyfile" &&\
	rm -f "$keyfile" ||\
	(
		exitcode=$!
		rm -f "$keyfile"
		exit $exitcode
	)
}

system_suffix="-disk-1"
docker_suffix="-disk-2"

device=""
systemvol=""
init_systemvol=1
init_dockervol=0
platform=qemu
stream=stable
kargs=""
config_yaml=""
coreos_unpacked_image=""
coreos_losetup_device=""

while [ "$#" -gt 0 ]
do
	case "$1" in
	-s|--system-disk)
		systemvol="$2"
		shift 2
		;;
	-n|--name)
		if [ -z "$systemvol" ]
		then
			systemvol="/dev/zvol/${2}${system_suffix}"
		fi
		shift 2
		;;
	-c|--config)
		config_yaml="$2"
		shift 2
		;;
	-p|--platform)
		platform="$2"
		shift 2
		;;
	--help)
		(
			echo "Usage: $0 [OPTIONS...]"
			echo ""
			echo "OPTIONS:"
			echo ""
			echo "  -s DISK, --system-disk DISK"
			echo "    Use this path as the system disk device."
			echo "  -c FILE, --config FILE"
			echo "    Use this path as the ignition YAML input file. JSON will be generated from it on the fly."
			echo "  -p PLATFORM, --platform PLATFORM"
			echo "    Set the CoreOS platform for this installation."
			echo "  -n vm-XXXX, --name vm-XXXX"
			echo "    Set device paths where not defined by deriving the paths from the given name as ZFS volumes."
			echo "  --help"
			echo "    Show this help text."
		) >&2
		exit 0
		;;
	*)
		echo "ERROR: Unrecognized argument: $1" >&2
		exit 1
		;;
	esac
done

if [ -z "$systemvol" ]
then
	echo "ERROR: Need a system volume to write to." >&2
	exit 1
fi

if [ ! -b "$systemvol" ]
then
	echo "ERROR: $systemvol is not a valid block device path." >&2
	exit 1
fi

cleanup() {
	if [ -n "$coreos_losetup_device" ]
	then
		sudo losetup -d "$coreos_losetup_device" || true
	fi
	if [ -d "$coreos_boot_mount_dir" ]
	then
		sudo umount "$coreos_boot_mount_dir" || true
		rmdir "$coreos_boot_mount_dir"
	fi
	if [ -n "$coreos_unpacked_image" ]
	then
		rm -f "$coreos_unpacked_image"
	fi
}
trap cleanup EXIT

# Import GnuPG keys for verification
mkdir -p "$(dirname "$gpg_keyring")"
# ref https://getfedora.org/security/
gpg_import_key "https://getfedora.org/static/fedora.gpg" sha512 8105b0fdba15a89cc1e1072cd002b87c6f2e86f9addb32248eb997c8ed36ab203cd66d47e8c08765e28d268683fdd01b81aa46d705510a32895075f27fa1e272
# ref https://coreos.com/security/app-signing-key/
#gpg_import_key "https://coreos.com/dist/pubkeys/app-signing-pubkey.gpg" sha512 17c3e3c7185e52db7c7590ff5d92f11ff42b7384903b9d162691b3e1ec22a07a318f17c2806c58e3e33b2f5f51e0f804ec7fcce41aa78011be179f6c5126471a

# Git
if ! command -v git >/dev/null 2>/dev/null
then
	echo "ERROR: You need git to run this tool." >&2
	exit 1
fi

# Golang compiler
go_version=1.13.6
go_tar_checksum=a1bc06deb070155c4f67c579f896a45eeda5a8fa54f35ba233304074c4abbbbd
go_dir="$app_dir/go-${go_version}"
go_bin="${go_dir}/bin/go"
go_tar_url="https://dl.google.com/go/go${go_version}.linux-amd64.tar.gz"
go_tar_filename="go-${go_version}.tar.gz"
if [ ! -f "$go_bin" ] || [ -f "$go_tar_filename" ]
then
	# ref https://golang.org/dl/
	download "$go_tar_url" sha256 "$go_tar_checksum" "$go_tar_filename"
	mkdir -vp "$go_dir"
	tar -x -C "$go_dir" -f "$go_tar_filename" --strip 1
	rm "$go_tar_filename"
fi
PATH="$(dirname "${go_bin}"):$PATH"
export PATH
GOPATH="${script_dir}/gopath"
export GOPATH
eval "$("${go_bin}" env)"

# Fedora CoreOS Configuration Transpiler (ignition)
fcct_version=0.4.0
fcct_dir="$app_dir/fcct-${fcct_version}"
fcct_bin="${fcct_dir}/bin/${GOARCH}/fcct"
fcct_git_url="https://github.com/coreos/fcct.git"
if [ ! -f "$fcct_bin" ]
then
	# Compile from source
	clone "${fcct_git_url}" "v${fcct_version}" "${fcct_dir}"
	(cd "$fcct_dir" && ./build)
fi
PATH="$(dirname "$fcct_bin"):$PATH"
export PATH

# Cargo
CARGO_HOME="$app_dir/cargohome"
export CARGO_HOME
RUSTUP_HOME="$app_dir/rustuphome"
export RUSTUP_HOME
RUSTUP_TOOLCHAIN="stable"
export RUSTUP_TOOLCHAIN
cargo_bin="${CARGO_HOME}/bin/cargo"
if [ ! -f "${cargo_bin}" ] || [ -f rustup.sh ]
then
	download https://sh.rustup.rs sha512 "39ce80b06b2ba8dd74043e04cc973533356c2135be3ee7dd95b47a6ffd380eec555d9e9103d539b1639b3412fa973617b8af97f647ffb13e1f8c536936aaaab3" rustup.sh
	sh ./rustup.sh --no-modify-path --profile minimal --default-toolchain stable --quiet -y </dev/null
	rm -f rustup.sh
fi
PATH="$(dirname "$cargo_bin"):$PATH"
export PATH

# CoreOS installer tool
coreos_installer_version=0.1.0
coreos_installer_dir="$app_dir/coreos-installer-${coreos_installer_version}"
coreos_installer_bin="${coreos_installer_dir}/target/release/coreos-installer"
coreos_installer_git_url="https://github.com/coreos/coreos-installer.git"
if [ ! -f "$coreos_installer_bin" ]
then
	# Compile from source
	clone "${coreos_installer_git_url}" "v${coreos_installer_version}" "${coreos_installer_dir}"
	(cd "$coreos_installer_dir" && "$cargo_bin" build --release)
fi
PATH="$(dirname "$coreos_installer_bin"):$PATH"
export PATH

echo "Downloading CoreOS..."
coreos_image="$("${coreos_installer_bin}" download)"
coreos_image_to_use="$coreos_image"

if [ -n "$config_yaml" ] || [ "$platform" != "metal" ] || [ -n "$kargs" ]
then
	echo "Unpacking CoreOS..."
	coreos_unpacked_image="$(basename "$coreos_image" .xz)"
	rm -f "$coreos_unpacked_image"
	xz -vkd "$coreos_image"

	coreos_losetup_device="$(sudo losetup --show -f -P "$coreos_unpacked_image")"
	coreos_boot_mount_dir="$(mktemp -d)"
	sudo mount "${coreos_losetup_device}p1" "$coreos_boot_mount_dir" || (
		# Create new downgraded version of the ext4 partition since some systems can't deal with it being mounted read-write
		echo "Rewriting boot partition for this system so it can be modified, this could take a good while..."
		sudo mount -o ro "${coreos_losetup_device}p1" "$coreos_boot_mount_dir"
		downgrade_ext4_archive="$(mktemp -p /var/tmp XXXXXXXX.tar)"
		(
			tar -v -c -C "$coreos_boot_mount_dir" -p -f "$downgrade_ext4_archive" --exclude=lost+found .
			sudo umount "${coreos_losetup_device}p1"
			blkid="$(export PATH=/usr/sbin:/sbin:$PATH && command -v blkid)"
			if [ -z "$blkid" ]
			then
				echo "ERROR: blkid not found, can not continue. Please install util-linux." >&2
				exit 1
			fi
			uuid=$("$blkid" -o value -s UUID "${coreos_losetup_device}p1")
			sudo mkfs.ext4 -F -L boot -U "$uuid" "${coreos_losetup_device}p1"
			sudo mount "${coreos_losetup_device}p1" "$coreos_boot_mount_dir"
			sudo tar -v -x -C "$coreos_boot_mount_dir" -p -f "$downgrade_ext4_archive"
		) || (
			exitcode=$!
			sudo rm -f "$downgrade_ext4_archive"
			exit $exitcode
		)
		sudo rm -f "$downgrade_ext4_archive"
	)

	if [ -n "$config_yaml" ]
	then
		echo "Generating ignition configuration from $config_yaml..." >&2
		sudo mkdir -p "$coreos_boot_mount_dir/ignition"
		fcct \
			-input "$config_yaml" |\
		sudo tee "${coreos_boot_mount_dir}/ignition/config.ign" >/dev/null
	fi

	if [ "$platform" != "metal" ]
	then
		echo "Patching bootloader entries..." >&2
		for config in "$coreos_boot_mount_dir"/loader/entries/*.conf
		do
			sudo sed -i "s#ignition.platform.id=metal#ignition.platform.id=${platform}#g" "$config"
		done
	fi

	if [ -n "$kargs" ]
	then
		echo "Writing first-boot kernel arguments..." >&2
		echo "set ignition_network_kcmdline=\"$kargs\"" | sudo tee -a "$coreos_boot_mount_dir"/ignition.firstboot
	fi

	sudo umount "$coreos_boot_mount_dir"
	rmdir "$coreos_boot_mount_dir"
	coreos_boot_mount_dir=""
	sudo losetup -d "$coreos_losetup_device"
	coreos_losetup_device=""
	coreos_image_to_use="$coreos_unpacked_image"
fi

echo "Installing CoreOS to $systemvol..." &&\
sudo -E "${coreos_installer_bin}" install "$systemvol" \
	--image-file "$coreos_image_to_use" \
	--insecure \
	--stream "$stream" &&\
rm -f "$ignitionfile" ||\
(
	exitcode=$!
	rm -f "$ignitionfile"
	echo "ERROR: CoreOS installation failed." >&2
	exit $exitcode
)
