#!/bin/bash -ex

CURDIR=$(pwd)
PROGNAME=${0##*/}

usage() {
    cat << EOF
Usage: $PROGNAME [OPTION]

  -h, --help             Display this help
  --force                Update, even if the signature checks fail
  --dir DIR              Update from DIR, instead of downloading
EOF
}

TEMP=$(
    getopt -o '' \
        --long dir: \
        --long force \
        --long nocheck \
	--long help \
        -- "$@"
    )

if (( $? != 0 )); then
    usage >&2
    exit 1
fi

eval set -- "$TEMP"
unset TEMP

while true; do
    case "$1" in
        '--dir')
	    USE_DIR="$(readlink -e $2)"
            shift 2; continue
            ;;
        '--force')
	    FORCE="y"
            shift 1; continue
            ;;
        '--nocheck')
	    NO_CHECK="y"
            shift 1; continue
            ;;
        '--help')
	    usage
	    exit 0
            ;;
        '--')
            shift
            break
            ;;
        *)
            echo 'Internal error!' >&2
            exit 1
            ;;
    esac
done

BASEURL="$1"

. /etc/os-release

CURRENT_ROOT_HASH=$(</proc/cmdline)
CURRENT_ROOT_HASH=${CURRENT_ROOT_HASH#*roothash=}
CURRENT_ROOT_HASH=${CURRENT_ROOT_HASH%% *}

CURRENT_ROOT_UUID=${CURRENT_ROOT_HASH:32:8}-${CURRENT_ROOT_HASH:40:4}-${CURRENT_ROOT_HASH:44:4}-${CURRENT_ROOT_HASH:48:4}-${CURRENT_ROOT_HASH:52:12}

bootdisk() {
    UUID=$({ read -r -n 1 -d '' _; read -n 72 uuid; echo -n ${uuid,,}; } < /sys/firmware/efi/efivars/LoaderDevicePartUUID-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f)

    [[ $UUID ]] || return 1
    echo "/dev/disk/by-partuuid/$UUID"
    return 0
}

get_disk() {
    for dev in /dev/disk/by-path/*; do
        [[ $dev -ef $1 ]] || continue
        echo ${dev%-part*}
        return 0
    done
    return 1
}

ROOT_DEV=$(get_disk $(bootdisk))

if ! [[ $ROOT_DEV ]]; then
    echo "Current partitions booted from not found!"
    exit 1
fi

unset FOUND
for dev in ${ROOT_DEV}-part*; do
    [[ $(blkid -o value -s PARTLABEL $dev) == root1 ]] &&
        ROOT1_DEV=$dev

    [[ $(blkid -o value -s PARTLABEL $dev) == root2 ]] &&
        ROOT2_DEV=$dev

    [[ $(blkid -o value -s PARTUUID $dev) == $CURRENT_ROOT_UUID ]] &&
        CURRENT_ROOT_DEV=$dev

    [[ $ROOT1_DEV ]] && [[ $ROOT2_DEV ]] && [[ $CURRENT_ROOT_DEV ]] && break
done

if ! [[ $ROOT1_DEV ]] || ! [[ $ROOT2_DEV ]] || ! [[ $CURRENT_ROOT_DEV ]]; then
    echo "Couldn't find partition numbers"
    exit 1
fi

[[ $CURRENT_ROOT_DEV == $ROOT2_DEV ]] \
    && NEW_ROOT_NUM=1 && OLD_ROOT_NUM=2 \
    && NEW_ROOT_PARTNO=${ROOT1_DEV##*-part}


[[ $CURRENT_ROOT_DEV == $ROOT1_DEV ]] \
    && NEW_ROOT_NUM=2 && OLD_ROOT_NUM=1 \
    && NEW_ROOT_PARTNO=${ROOT2_DEV##*-part}

ROOT_PARTNO=${CURRENT_ROOT_DEV##*-part}

if ! [[ $NEW_ROOT_PARTNO ]] || ! [[ $ROOT_PARTNO ]] || ! [[ $ROOT_DEV ]]; then
    echo "Couldn't find partition numbers"
    exit 1
fi

mkdir -p /var/cache/${NAME}
cd /var/cache/${NAME}

if ! [[ $USE_DIR ]]; then
    curl ${BASEURL}/${NAME}-latest.json --output ${NAME}-latest.json

    IMAGE="$(jq -r '.name' ${NAME}-latest.json)-$(jq -r '.version' ${NAME}-latest.json)"
    ROOT_HASH=$(jq -r '.roothash' ${NAME}-latest.json)

    if ! [[ $FORCE ]] && [[ $CURRENT_ROOT_HASH == $ROOT_HASH ]]; then
        echo "Already up2date"
        exit 1
    fi

    [[ -d ${IMAGE} ]] || curl ${BASEURL}/${IMAGE}.tgz | tar xzf -
else
    IMAGE="$USE_DIR"
    ROOT_HASH=$(<"$IMAGE"/root-hash.txt)

    if ! [[ $FORCE ]] && [[ $CURRENT_ROOT_HASH == $ROOT_HASH ]]; then
        echo "Already up2date"
        exit 1
    fi
fi

[[ -d ${IMAGE} ]]

cd ${IMAGE}

if ! [[ $NO_CHECK ]]; then
    # check integrity
    gpg2 --no-default-keyring --keyring /etc/pki/${NAME}/GPG-KEY --verify sha512sum.txt.sig sha512sum.txt
    sha512sum -c sha512sum.txt
fi

dd status=progress if=root.img of=${ROOT_DEV}-part${NEW_ROOT_PARTNO}

# set the new partition uuids
ROOT_UUID=${ROOT_HASH:32:8}-${ROOT_HASH:40:4}-${ROOT_HASH:44:4}-${ROOT_HASH:48:4}-${ROOT_HASH:52:12}

sfdisk --part-uuid ${ROOT_DEV} ${NEW_ROOT_PARTNO} ${ROOT_UUID}

# install to /efi
mkdir -p /efi/EFI/${NAME}
cp bootx64.efi /efi/EFI/${NAME}/${NEW_ROOT_NUM}.efi

mv /efi/EFI/${NAME}/${OLD_ROOT_NUM}.efi /efi/EFI/${NAME}/_${OLD_ROOT_NUM}.efi || :
rm -f /efi/EFI/${NAME}/_${NEW_ROOT_NUM}.efi