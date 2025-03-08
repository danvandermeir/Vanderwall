#!/bin/bash
unset IFS
WANIF='eth0'
WARNING=true
err() {
	[ -n "$1" ] && printf -- "$1\n" 1>&2 && return 0
	return 1
}
errout() {
	err "$1"
	exit 1
}
BINARIES=('ip' 'ifdown' 'ifup' 'ping' 'mkiptables' 'googledns')
for x in "${!BINARIES[@]}"; do
	BINARIES[$x]="$(command -v ${BINARIES[$x]})" || errout "Required binaries (applications/scripts) not available!"
done
isip() {
	if [ -z "$1" ] || [[ ! $1 =~ ^[0-9/.]+$ ]]; then
		$WARNING && err "$1 is not a valid IPv4 address!"
		return 1
	fi
	local a1 a2 a3 a4 v
	a4="$1"
	a1=${a4//.}
	if [ $((${#a4} - ${#a1})) -ne 3 ]; then
		$WARNING && err "$1 is not a valid IPv4 address!"
		return 1
	fi
	for y in {1..4}; do
		declare a$y="${a4%%.*}"
		v="a$y"
		if [ -z "${!v}" ] || [ ${!v} -gt 255 ]; then
			$WARNING && err "$1 is not a valid IPv4 address!"
			return 1
		fi
		a4="${a4#*.}"
	done
	return 0
}
getgw() {
	[ -z $2 ] && errout "Cannot get gateway from empty interface name! Exiting!"
	local GW
	GW="$(${1} r|grep ${2}|grep -m 1 'via')"
	GW=${GW#*via }
	GW=${GW%% *}
	if [ -z $GW ]; then
		$WARNING && err "Interface $2 has no valid gateway!"
		return 1
	else
		printf "$GW"
		return 0
	fi
}
WANGW="$(getgw ${BINARIES[0]} ${WANIF})"
PNGCT=0
while sleep 0.25; do
	while ! ${BINARIES[3]} -q -i 0.2 -c 1 "${WANGW}" -I "${WANIF}" &>/dev/null; do
		PNGCT=$((PNGCT+1))
		if [ $PNGCT -eq 4 ]; then
			unset WANGW
			while [ -z $WANGW ] || ! isip ${WANGW}; do
				${BINARIES[1]} ${WANIF}
				${BINARIES[2]} ${WANIF}
				WANGW="$(getgw ${BINARIES[0]} ${WANIF})"
			done
			PNGCT=0
			${BINARIES[4]}
			${BINARIES[5]}
		fi
	done
	PNGCT=0
done
