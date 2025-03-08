#!/bin/bash
unset IFS

#	WANs or interfaces to serve only authoratative responses (E.G. 'eth1' will only work with 'public,' or LANHOSTS specifically naming DNSWANINTS below) - supersedes duplicates in DNSLANINTS
DNSWANINTS=('')

#	interface names to serve general DNS requests on (E.G. 'eth0') - superseded by duplicates in DNSWANINTS
#	prepend CIDR network for non-local (VLANs?) or limited networks routing DNS requests here (E.G. '192.168.0.0/16,eth0'), assure non-local requests arrive on the default gateway interface
#	BE ABSOLUTELY TO NOT CREATE AN OPEN RESOLVER!! DO NOT RESOLVE REQUESTS TO "THE INTERNET"!!!
DNSLANINTS=('')

#	to force requests to be forwarded to another domain name server for a specific interface list the DNS IP here
#	this array should match DNSLANINTS, blank entries treated as default resolver type unless RESOLVERS set, overides RESOLVERS
FORWARDERS=('')

#	to force recursive requests out specific interfaces when received on a specific interface enter the interface name or IP here
#	this array should match DNSLANINTS, blank entries treated as default resolver type, FORWARDERS will overide this option
RESOLVERS=('')

#	hostnames to resolve as authorative server (this includes subdomains, such subdomains could be overiden with a new hostname entry)
HOSTNAMES=('')

#	the IP the HOSTNAMES entry will be resolved to for requests on all interfaces listed in DNSLANINTS
#	prepending 'all,' to an entry will take a host portion of an IP (E.G. 'all,.5') and attempt to apply that host to all DNSLANINTS listed interface networks
#	prepending an interface name listed in DNSLANINTS will make only that interface redirect hostname requests to the specified IP (E.G. 'eth0,192.168.8.5')
#	prepending 'public,' to the specified IP causes "WAN" connections to respond to requests only for listed hostnames (E.G. 'public,64.63.62.61')
LANHOSTS=('')

err() {
	[ -n "$1" ] && printf -- "$1\n" 1>&2 && return 0
	return 1
}
errout() {
	err "$1"
	exit 1
}
isnum() {
	[ -z "$1" ] || ! [[ $1 =~ ^[0-9]+$ ]] && err "Invalid numbers ($1)!" && return 1
	return 0
}
isip() {
	[ -z "$1" ] || [[ ! $1 =~ ^[0-9/.]+$ ]] && err "Invalid IP address ($1)!" && return 1
	local a1 a2 a3 a4 v
	a4="$1"
	a1=${a4//.}
	[ $((${#a4} - ${#a1})) -ne 3 ] && err "Invalid IP address ($1)!" && return 1
	for y in {1..4}; do
		declare a$y="${a4%%.*}"
		v="a$y"
		[ -z "${!v}" ] || [ ${!v} -gt 255 ] && err "Invalid IP address ($1)!" && return 1
		a4="${a4#*.}"
	done
	return 0
}
iscidr() {
	[ -z "$1" ] || [[ ! $1 =~ ^[0-9/./\/]+$ ]] || ! isip "${1%/*}" && err "Invalid CIDR address ($1)!" && return 1
	local m1
	m1="${1#*/}"
	[ -z "$m1" ] || ! isnum "$m1" || [ $m1 -lt 8 ] || [ $m1 -gt 32 ] && err "Invalid CIDR address ($1)!" && return 1
	return 0
}
cidrtomask() {
	[ -z "$1" ] || [[ ! $1 =~ ^[0-9]+$ ]] || [ $1 -lt 8 ] || [ $1 -gt 32 ] && errout "CIDR bit length not provided to cidrtomask function (expected 8-32, got '$1')!"
	local i mask full part
	full=$(($1/8))
	part=$(($1%8))
	for ((i=0;i<4;i+=1)); do
		if [ $i -lt $full ]; then
			mask+=255
		elif [ $i -eq $full ]; then
			mask+=$((256 - 2**(8-$part)))
		else
			mask+=0
		fi
		test $i -lt 3 && mask+=.
	done
	printf "$mask"
	return 0
}
networkmin() {
	 [ -z $1 ] || ! iscidr "$1" && errout 'CIDR address not provided to networkmin function!'
	local a1 a2 a3 a4 m1 m2 m3 m4
	IFS=. read -r a1 a2 a3 a4<<<"${1%/*}"
	IFS=. read -r m1 m2 m3 m4<<<"$(cidrtomask ${1#*/})"
	a1=$((a1 & m1))
	a2=$((a2 & m2))
	a3=$((a3 & m3))
	a4=$((a4 & m4))
	printf "$a1.$a2.$a3.$a4"
	return 0
}
inntwrk() {
	[ -z "$1" ] || ! isip "$1" && return 1
	[ -z "$2" ] || ! iscidr "$2" && return 1
	[ "$(networkmin $1/${2#*/})" != "$(networkmin $2)" ] && return 1
	return 0
}
makezones() {
	[ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ] || ! isip "$3" || ! isip "$4" && err "Malformed makedbzone call, requires (interface name, hostname, interface IP, hostname IP), received ($1, $2, $3, $4)" && return 1
	printf "zone \"$2\" {
        type master;
        file \"/etc/bind/db_$1.$2\";
};\n">>/etc/bind/named.$1.zone
	printf "\$TTL   604800
@		IN		SOA		$2. root.$2. (
				1		; Serial
				604800		; Refresh
				86400		; Retry
				2419200		; Expire
				604800 )	; Negative Cache TTL
@		IN		NS		lns1.$2.
lns1.$2.	IN		A		$3
@		IN		A		$4
*		IN		A		$4\n">/etc/bind/db_$1.$2
	return 0
}
recintcheck() {
	[ -z "$1" ] && return 1
	local x y internum
	[ -z "$2" ] && internum=1 || internum="$2"
	y=true
	for x in "${!LANINTS[@]}"; do
		[ "${LANINTS[$x]}" = "$1"'m'"$internum" ] && y=false && break 1
	done
	if $y; then
		printf "$1"'m'"$internum"
		return 0
	else
		internum=$((internum+1))
		internum=$(recintcheck $1 $internum)
		printf "$internum"
		return 0
	fi
}
#       Verify all interfaces and get addresses/networks
declare -a WANINTS=()
for x in "${!DNSWANINTS[@]}"; do
	WANINTS[$x]="${DNSWANINTS[$x]}"
done
for x in "${!WANINTS[@]}"; do
	WANINTS[$x]="${WANINTS[$x]%%@*}"
	WANCIDRS[$x]=$(ip a show ${WANINTS[$x]} 2>/dev/null|grep -m 1 -w 'inet')
	if [ -z "${WANCIDRS[$x]}" ]; then
		ERRMESS="WAN interface ${WANINTS[$x]} (array # $x) does not have a valid IPv4 address, will not configure this interface!"
		$WARNING && err "$ERRMESS"
		unset WANINTS[$x] WANOUTS[$x] WANCIDRS[$x] DNSWANINTS[$x]
		continue 1
	fi
	WANCIDRS[$x]=${WANCIDRS[$x]#*inet }
	WANCIDRS[$x]=${WANCIDRS[$x]%% *}
	if ! iscidr "${WANCIDRS[$x]}"; then
		ERRMESS="WAN interface ${WANINTS[$x]} (array # $x) will not be configured!"
		$WARNING && err "$ERRMESS"
		unset WANINTS[$x] WANOUTS[$x] WANCIDRS[$x] DNSWANINTS[$x]
		continue 1
	fi
	WANIPS[$x]=${WANCIDRS[$x]%/*}
	WANCIDRS[$x]="$(networkmin ${WANCIDRS[$x]})/${WANCIDRS[$x]#*/}"
done
declare -a LANINTS=()
for x in $(ip link show up|grep -vi -e 'link/ether' -e 'loopback'|cut -d' ' -f2|cut -d':' -f1); do
	x="${x%%\@*}"
	z=false
	for y in "${!WANINTS[@]}"; do
		[ "$x" = "$WANINTS[$y]" ] && z=true && break 1
	done
	$z && continue 1
	LANINTS+=("$x")
done
for x in "${!LANINTS[@]}"; do
	LANCIDRS[$x]=$(ip a show ${LANINTS[$x]} 2>/dev/null|grep -m 1 -w 'inet')
	if [ -z "${LANCIDRS[$x]}" ]; then
		unset LANINTS[$x] LANOUTS[$x] LANCIDRS[$x]
		continue 1
	fi
	LANCIDRS[$x]=${LANCIDRS[$x]#*inet }
	LANCIDRS[$x]=${LANCIDRS[$x]%% *}
	if ! iscidr "${LANCIDRS[$x]}"; then
		unset LANINTS[$x] LANOUTS[$x] LANCIDRS[$x]
		continue 1
	fi
	LANIPS[$x]=${LANCIDRS[$x]%/*}
	LANCIDRS[$x]="$(networkmin ${LANCIDRS[$x]})/${LANCIDRS[$x]#*/}"
done
#		input santization
for x in "${!DNSLANINTS[@]}"; do
	if [[ "${DNSLANINTS[$x]}" = *","* ]]; then
		unset DNSALLIP
		z="${DNSLANINTS[$x]##*,}nl$x"
		for y in "${!LANINTS[@]}"; do
			[ "$z" = "${LANINTS[$y]}" ] || continue 1
			DNSALLIP=$(recintcheck $z)
			[ -z "$DNSALLIP" ] && break 1
			LANINTS+=("$DNSALLIP")
			LANIPS+=("$LANIPS[$y]")
			LANCIDRS+=("${DNSLANINTS[$x]%%,*}")
			break 1
		done
		[ -z "$DNSALLIP" ] && err "No LAN interfaces found matching requested $z (${DNSLANINTS[$x]}), will not set up!" && unset DNSLANINTS[$x]
		continue 1
	fi
	z=false
	for y in "${!WANINTS[@]}"; do
		[ "${DNSLANINTS[$x]}" = "${WANINTS[$y]}" ] && z=true && err "Requested DNSLANINTS ${DNSLANINTS[$x]} is a WAN interface! Treating as DNSWANINTS!" && unset DNSLANINTS[$x] && break 1
	done
	if ! $z; then
		for y in "${!LANINTS[@]}"; do
			[ "${DNSLANINTS[$x]}" = "${LANINTS[$y]}" ] && z=true && break 1
		done
	fi
	$z || err "DNSLANINTS ${DNSLANINTS[$x]} is not a WAN or LAN interface! Will not use!" && unset ${DNSLANINTS[$x]}
done
for x in "${!RESOLVERS[@]}"; do
	z=false
	for y in "${!LANINTS[@]}"; do
		[ "$RESOLVERS[$x]}" = "${LANINTS[$y]}" ] && z=true && RESOLVERS[$x]="${LANIPS[$y]}" && break 1
		[ "$RESOLVERS[$x]}" = "${LANIPS[$y]}" ] && z=true && break 1
	done
	if ! $z; then
		for y in "${!WANINTS[@]}"; do
			[ "$RESOLVERS[$x]}" = "${WANINTS[$y]}" ] && z=true && RESOLVERS[$x]="${WANIPS[$y]}" && break 1
			[ "$RESOLVERS[$x]}" = "${WANIPS[$y]}" ] && z=true && break 1
		done
	fi
	$z || err "Resolver ${RESOLVERS[$x]} (array index $x) is not a WAN or LAN interface or IP! Will not use!" && unset ${RESOLVERS[$x]} && continue 1
done
#		generate named.conf
printf '// This is the primary configuration file for the BIND DNS server named.
//
// Please read /usr/share/doc/bind9/README.Debian for information on the
// structure of BIND configuration files in Debian, *BEFORE* you customize
// this configuration file.
//
// If you are just adding zones, please do that in /etc/bind/named.conf.local

include "/etc/bind/named.conf.options";
include "/etc/bind/named.conf.local";
#include "/etc/bind/named.conf.default-zones";'"\n">/etc/bind/named.conf
#		generate named.conf.options and reset interface zone files
unset ncf
for x in "${!DNSLANINTS[@]}"; do
	>/etc/bind/named.${DNSLANINTS[$x]}.zone
	for y in "${!LANINTS[@]}"; do
		[ "${DNSLANINTS[$x]}" = "${LANINTS[$y]}" ] || continue 1
		ncf="$ncf
acl ${DNSLANINTS[$x]}-acl { ${LANCIDRS[$y]}; };"
		break 1
	done
done
for x in "${!DNSWANINTS[@]}"; do
	>/etc/bind/named.${DNSWANINTS[$x]}.zone
	for y in "${!WANINTS[@]}"; do
		[ "${DNSWANINTS[$x]}" = "${WANINTS[$y]}" ] || continue 1
		ncf="$ncf
acl ${DNSWANINTS[$x]}-acl { ${WANCIDRS[$y]}; };"
		break 1
	done
done
ncf="$ncf
options {
	directory \"/var/cache/bind\";
	notify no;
	minimal-responses yes;
	empty-zones-enable no;
	disable-empty-zone yes;
	auth-nxdomain yes;
	allow-transfer { none; };
	dnssec-validation auto;
	listen-on port 53 {
		0.0.0.0/0;
	};
	listen-on-v6 { none; };
	allow-query {"
for x in "${!DNSWANINTS[@]}"; do
	ncf="$ncf
		\"${DNSWANINTS[$x]}-acl\";"
done
for x in "${!DNSLANINTS[@]}"; do
	ncf="$ncf
		\"${DNSLANINTS[$x]}-acl\";"
done
ncf="$ncf
		localhost;
	};
	allow-query-cache {"
for x in "${!DNSLANINTS[@]}"; do
	ncf="$ncf
		\"${DNSLANINTS[$x]}-acl\";"
done
ncf="$ncf
		\"localhost\";
	};
	recursion yes;
	allow-recursion {"
for x in "${!DNSLANINTS[@]}"; do
	ncf="$ncf
		\"${DNSLANINTS[$x]}-acl\";"
done
ncf="$ncf
		\"localhost\";
	};
};"
for x in "${!DNSWANINTS[@]}"; do
	ncf="$ncf
view \"${DNSWANINTS[$x]}-view\" {
	match-clients { ${DNSWANINTS[$x]}-acl; };
	include \"/etc/bind/named.${DNSWANINTS[$x]}.zone\";
};"
done
for x in "${!DNSLANINTS[@]}"; do
	ncf="$ncf
view \"${DNSLANINTS[$x]}-view\" {
	match-clients { ${DNSLANINTS[$x]}-acl; };
	include \"/etc/bind/named.conf.default-zones\";
	include \"/etc/bind/named.${DNSLANINTS[$x]}.zone\";"
	if [ -n "${FORWARDERS[$x]}" ]; then
		if isip "${FORWARDERS[$x]}"; then
			ncf="$ncf
	zone \".\" {
		type forward;
		forward only;
		forwarders { ${FORWARDERS[$x]}; };
	};"
		else
			err "Interface ${DNSLANINTS[$x]} forwarder ${FORWARDERS[$x]} is invalid IP! Interface being set up as default recursive!"
		fi
	elif [ -n "${RESOLVERS[$x]}" ]; then
		ncf="$ncf
	zone \".\" {
		query-source ${RESOLVERS[$x]};
	};"
	fi
	ncf="$ncf
};"
done
printf "$ncf\n">/etc/bind/named.conf.options
#		generate zone files
[ ${#DNSLANINTS[@]} -eq 0 ] && [ ${#DNSWANINTS[@]} -eq 0 ] && errout 'No interfaces are handling DNS!'
for x in "${!HOSTNAMES[@]}"; do
	if [[ "${LANHOSTS[$x]}" = "all,"* ]]; then
		for y in "${!LANINTS[@]}"; do
			for z in "${!DNSLANINTS[@]}"; do
				if [ "${DNSLANINTS[$z]}" = "${LANINTS[$y]}" ]; then
					neti="$y"
					DNSALLIP="${LANHOSTS[$x]##*,}"
					begin="${LANCIDRS[$neti]%.*}"
					track="${LANCIDRS[$neti]%%.*}"
					while !	isip "$begin$DNSALLIP"; do
						begin="${begin%.*}"
						[ "$track" = "$begin" ] && err "Hostname ${HOSTNAMES[$x]} has malformed entry (${LANHOSTS[$x]})! Will not set this hostname!" && unset DNSALLIP && break 3
					done
					DNSALLIP="$begin$DNSALLIP"
					if ! inntwrk "$DNSALLIP" "${LANCIDRS[$neti]}"; then
						err "Hostname ${HOSTNAMES[$x]} LAN host $DNSALLIP (${LANHOSTS[$x]}) not in ${LANINTS[$neti]} network (${LANCIDRS[$neti]})! Will not set on this interface!"
						break 1
					fi
					if grep -qi "/"${HOSTNAMES[$x]}/"" "/etc/bind/named.${LANINTS[$neti]}.zone"; then
						err "Hostname ${HOSTNAMES[$x]} (${LANHOSTS[$x]}) already exists for interface ${LANINTS[$neti]}, will not set on this interface!"
						break 1
					fi
					makezones "${LANINTS[$neti]}" "${HOSTNAMES[$x]}" "${LANIPS[$neti]}" "$DNSALLIP"
					break 1
				fi
			done
		done
	elif [[ "${LANHOSTS[$x]}" = "public,"* ]]; then
		for y in "${DNSWANINTS[@]}"; do
			unset DNSALLIP
			for z in "${WANINTS[@]}"; do
				[ "${DNSWANINTS[$Y]}" = "${WANINTS[$z]}" ]- || continue 1
				if grep -qi "/"${HOSTNAMES[$x]}/"" "/etc/bind/named.${DNSWANINTS[$Y]}.zone"; then
					err "Hostname ${HOSTNAMES[$x]} (${LANHOSTS[$x]}) already exists on public interface ${DNSWANINTS[$Y]}, will not set for this interface!"
					break 1
				fi
				DNSALLIP="${LANHOSTS[$x]##*,}"
				isip "$DNSALLIP" || err "Hostname ${HOSTNAMES[$x]} (${LANHOSTS[$x]}) does not contain a valid IP, will not set!" && break 1
				makezones "${DNSWANINTS[$y]}" "${HOSTNAMES[$x]}" "${WANIPS[$z]}" "$DNSALLIP"
				break 1
			done
			[ -z "$DNSALLIP" ] && err "Invalid WAN interface requested ($DNSWANINTS[$y]) for hostname ${HOSTNAMES[$x]} (${LANHOSTS[$x]})!"
		done
	elif [[ "${LANHOSTS[$x]}" = *","* ]]; then
		unset DNSALLIP
		isip "${LANHOSTS[$x]##*,}" || err "Hostname ${HOSTNAMES[$x]} (${LANHOSTS[$x]}) does not contain a valid IP, will not set!" && continue 1
		z="${LANHOSTS[$x]%%,*}"
		for y in "${!DNSLANINTS[@]}"; do
			[ "$z" = "${DNSLANINTS[$y]}" ] || continue 1
			for z in "${!LANINTS[@]}"; do
				[ "${DNSLANINTS[$y]}" = "${LANINTS[$z]}" ] || continue 1
				DNSALLIP="${LANHOSTS[$x]##*,}"
				if grep -qi "/"${HOSTNAMES[$x]}/"" "/etc/bind/named.${LANINTS[$y]}.zone"; then
					err "Hostname ${HOSTNAMES[$x]} (${LANHOSTS[$x]}) already exists for interface ${DNSLANINTS[$y]}, will not set for this interface!"
					break 1
				fi
				makezones "${DNSLANINTS[$y]}" "${HOSTNAMES[$x]}" "${LANIPS[$z]}" "$DNSALLIP"
				break 2
			done
			break 1
		done
		if [ -z "$DNSALLIP" ]; then
			for y in "${!DNSWANINTS[@]}"; do
				[ "$z" = "${DNSWANINTS[$y]}" ] || continue 1
				for z in "${!WANINTS[@]}"; do
					[ "${DNSWANINTS[$y]}" = "${WANINTS[$z]}" ] || continue 1
					DNSALLIP="${LANHOSTS[$x]##*,}"
					if grep -qi "/"${HOSTNAMES[$x]}/"" "/etc/bind/named.${WANINTS[$y]}.zone"; then
						err "Hostname ${HOSTNAMES[$x]} (${LANHOSTS[$x]}) already exists for interface ${DNSWANINTS[$y]}, will not set for this interface!"
						break 1
					fi
					makezones "${DNSWANINTS[$y]}" "${HOSTNAMES[$x]}" "${WANIPS[$z]}" "$DNSALLIP"
					break 2
				done
				break 1
			done
		fi
		[ -z "$DNSALLIP" ] && err "No matching DNS interface name for hostname ${HOSTNAMES[$x]} (${LANHOSTS[$x]}), will not be set!"
	else
		isip "${LANHOSTS[$x]}" || err "Hostname ${HOSTNAMES[$x]} (${LANHOSTS[$x]}) does not contain a valid IP, will not set!" && continue 1
		for y in "${!DNSLANINTS[@]}"; do
			if grep -qi "/"${HOSTNAMES[$x]}/"" "/etc/bind/named.${DNSLANINTS[$y]}.zone"; then
				err "Hostname ${HOSTNAMES[$x]} (${LANHOSTS[$x]}) already exists for interface ${DNSLANINTS[$y]}, will not set for this interface!"
				continue 1
			fi
			for z in "${!LANINTS[@]}"; do
				[ "${LANINTS[$z]}" = "${DNSLANINTS[$y]}" ] || continue 1
				makezones "${DNSLANINTS[$y]}" "${HOSTNAMES[$x]}" "${LANIPS[$z]}" "${LANHOSTS[$x]}"
				break 1
			done
		done
	fi
done
