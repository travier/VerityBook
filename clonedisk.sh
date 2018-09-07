#!/bin/bash -ex

usage() {
    cat << EOF
Usage: $PROGNAME [OPTION]

  -h, --help             Display this help
  --crypt                Use Luks2 to encrypt the data partition (default PW: 1)
  --crypttpm2            as --crypt, but additionally auto-open with the use of a TPM2
  --simple               do not use dual-boot layout (e.g. for USB install media)
  --update               do not clear the data partition
EOF
}

TEMP=$(
    getopt -o '' \
        --long crypt \
        --long crypttpm2 \
	--long simple \
	--long update \
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
        '--crypt')
	    USE_CRYPT="y"
            shift 1; continue
            ;;
        '--crypttpm2')
	    USE_TPM="y"
            shift 1; continue
            ;;
        '--simple')
	    SIMPLE="y"
            shift 1; continue
            ;;
        '--update')
	    UPDATE="y"
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

[[ $TMPDIR ]] || TMPDIR=/var/tmp
readonly TMPDIR="$(realpath -e "$TMPDIR")"
[ -d "$TMPDIR" ] || {
    printf "%s\n" "${PROGNAME}: Invalid tmpdir '$tmpdir'." >&2
    exit 1
}

readonly MY_TMPDIR="$(mktemp -p "$TMPDIR/" -d -t ${PROGNAME}.XXXXXX)"
[ -d "$MY_TMPDIR" ] || {
    printf "%s\n" "${PROGNAME}: mktemp -p '$TMPDIR/' -d -t ${PROGNAME}.XXXXXX failed." >&2
    exit 1
}

# clean up after ourselves no matter how we die.
trap '
    ret=$?;
    [[ $MY_TMPDIR ]] && mountpoint "$MY_TMPDIR"/data && umount "$MY_TMPDIR"/data
    [[ $MY_TMPDIR ]] && rm -rf --one-file-system -- "$MY_TMPDIR"
    exit $ret;
    ' EXIT

# clean up after ourselves no matter how we die.
trap 'exit 1;' SIGINT

mem=$(cat /proc/meminfo | { read a b a; echo $b; } )
mem=$(((mem-1)/1024/1024 + 1))
mem=${3:-$mem}

IN=$(readlink -e "$1")
OUT=$(readlink -e "$2")

[[ -b ${IN} ]]
[[ -b ${OUT} ]]

for i in ${OUT}*; do
    umount "$i" || :
done

if [[ ${IN#/dev/loop} != $IN ]]; then
    IN="${IN}p"
fi

if ! [[ $UPDATE ]]; then

    udevadm settle
    wipefs --all "$OUT"

    udevadm settle
    sfdisk -W always -w always "$OUT" << EOF
label: gpt
	    size=512MiB,  type=c12a7328-f81f-11d2-ba4b-00a0c93ec93b, name="ESP System Partition"
            size=64M,    type=2c7357ed-ebd2-46d9-aec1-23d437ec2bf5, name="ver1",   uuid=$(blkid -o value -s PARTUUID ${IN}2)
            size=4GiB,    type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="root1",  uuid=$(blkid -o value -s PARTUUID ${IN}3)
            size=64M,    type=2c7357ed-ebd2-46d9-aec1-23d437ec2bf5, name="ver2"
            size=4GiB,    type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, name="root2"
            size=${mem}GiB,  type=0657fd6d-a4ab-43c4-84e5-0933c84b4f4e, name="swap"
            type=3b8f8425-20e0-4f3b-907f-1a25a76f98e9, name="data"
EOF
    udevadm settle
fi

OUT_DEV=$OUT

if [[ ${OUT#/dev/loop} != $OUT ]]; then
    OUT="${OUT}p"
fi
if [[ ${OUT#/dev/nvme} != $OUT ]]; then
    OUT="${OUT}p"
fi

for i in 1 2 3; do 
    dd if=${IN}${i} of=${OUT}${i} status=progress
    sfdisk --part-uuid ${OUT_DEV} $i $(blkid -o value -s PARTUUID ${IN}${i})
done

if ! [[ $UPDATE ]]; then
    swapoff ${OUT}6 || :
    # ------------------------------------------------------------------------------
    # swap
    echo -n "zero key" \
        | cryptsetup luksFormat --type luks2 ${OUT}6 /dev/stdin

    # ------------------------------------------------------------------------------
    # data
    echo -n "zero key" \
        | cryptsetup luksFormat --type luks2 ${OUT}7 /dev/stdin
fi
