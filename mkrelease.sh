#!/bin/bash -ex

usage() {
    cat << EOF
Usage: $PROGNAME [OPTION]

  -h, --help             Display this help
  --nosign               Don't sign the EFI executable
  --dbkey KEY            Use KEY as certification key for EFI signing
  --dbcrt CRT            Use CRT as certification for EFI signing
EOF
}

TEMP=$(
    getopt -o '' \
        --long dbkey: \
        --long dbcrt: \
        --long nosign \
        --long notar \
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
        '--dbkey')
            DBKEY="$(readlink -e $2)"
            shift 2; continue
            ;;
        '--dbcrt')
            DBCRT="$(readlink -e $2)"
            shift 2; continue
            ;;
        '--nosign')
            NOSIGN="1"
            shift 1; continue
            ;;
        '--notar')
            NOTAR="1"
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

JSON="$(realpath -e $1)"
BASEDIR="${JSON%/*}"
IMAGE="${BASEDIR}/$(jq -r '.name' ${JSON})-$(jq -r '.version' ${JSON})"

pushd "$IMAGE"
if ! [[ $NOSIGN ]]; then
    if ! [[ $DBKEY ]] || ! [[ $DBCRT ]]; then
        echo "Need --dbkey KEY --dbcrt CRT options"
        exit 1
    fi
    for i in $(find . -type f -name '*.efi'); do
        [[ -f "$i" ]] || continue
        if ! sbverify --cert "$DBCRT" "$i" &>/dev/null ; then
            sbsign --key "$DBKEY" --cert "$DBCRT" --output "${i}signed" "$i"
            mv "${i}signed" "$i"
        fi
    done
fi
[[ -f sha512sum.txt ]] || sha512sum $(find . -type f) > sha512sum.txt
[[ -f sha512sum.txt.sig ]] || gpg2 --detach-sign sha512sum.txt

popd

if ! [[ $NOTAR ]] && ! [[ -e "$IMAGE".tgz ]]; then
    tar cf - -C "${IMAGE%/*}" "${IMAGE##*/}" | pigz -c > "$IMAGE".tgz
fi
