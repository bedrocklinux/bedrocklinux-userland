#!/bedrock/libexec/busybox sh

source /bedrock/share/common-code

to="${1}"
shift
ensure_legal_stratum_name "${to}"
if ! is_stratum "${to}"; then
	abort "no such stratum ${to}"
fi

from=$(get_attr / stratum)
if [ "${to}" = "${from}" ]; then
	abort "already there"
fi

if [ $# = 0 ]; then
	set -- sh
fi

script=$(cat << 'END'
set -x
to=$1
from=$2
shift 2
/bedrock/libexec/busybox pivot_root /bedrock/strata/${to} /bedrock/strata/${to}/bedrock/strata/${from}
/bedrock/libexec/busybox mount --move /bedrock/strata/${from}/bedrock /tmp
/bedrock/libexec/busybox mount --move /bedrock/strata/${from} /tmp/strata/${from}
/bedrock/libexec/busybox mount --move /bedrock /tmp/strata/${from}/bedrock
/tmp/libexec/busybox mount --move /tmp /bedrock
exec "$@"
END
)
exec unshare --mount /bedrock/libexec/busybox sh -c "$script" . "${to}" "${from}" "$@"
