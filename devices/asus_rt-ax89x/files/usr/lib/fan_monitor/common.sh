#!/bin/sh

# Shared hardware discovery helpers for luci-app-fan-monitor.
# Compatible with BusyBox ash.

HWMON_CLASS_ROOT=${HWMON_CLASS_ROOT:-/sys/class/hwmon}
THERMAL_CLASS_ROOT=${THERMAL_CLASS_ROOT:-/sys/class/thermal}
DT_BASE=${DT_BASE:-/sys/firmware/devicetree/base}

fm_is_uint() {
	case "$1" in
		''|*[!0-9]*) return 1 ;;
		*) return 0 ;;
	esac
}

fm_read_text() {
	FM_TEXT=''
	[ -r "$1" ] || return 1
	FM_TEXT="$(cat "$1" 2>/dev/null)" || return 1
	return 0
}

fm_read_dt_string() {
	FM_TEXT=''
	[ -r "$1" ] || return 1
	FM_TEXT="$(tr '\000' '\n' < "$1" 2>/dev/null | sed -n '1p')" || return 1
	[ -n "$FM_TEXT" ]
}

fm_uevent_value() {
	local file="$1" wanted="$2" line
	FM_TEXT=''
	[ -r "$file" ] || return 1
	while IFS= read -r line; do
		case "$line" in
			"$wanted"=*) FM_TEXT=${line#*=}; return 0 ;;
		esac
	done < "$file"
	return 1
}

fm_normalize_phy_id() {
	local raw
	FM_PHY_ID=''
	raw="$1"
	raw=${raw#0x}
	raw=${raw#0X}
	raw="$(printf '%s' "$raw" | tr 'A-F' 'a-f')"
	case "$raw" in
		''|*[!0-9a-f]*) return 1 ;;
	esac
	case ${#raw} in
		1) raw="0000000$raw" ;;
		2) raw="000000$raw" ;;
		3) raw="00000$raw" ;;
		4) raw="0000$raw" ;;
		5) raw="000$raw" ;;
		6) raw="00$raw" ;;
		7) raw="0$raw" ;;
		8) ;;
		*) return 1 ;;
	esac
	FM_PHY_ID="0x$raw"
	return 0
}

# Sets FM_AQR_MODEL for all AQR models known by current upstream Linux.
# The last nibble of a PHY ID is a silicon revision and is ignored by
# PHY_ID_MATCH_MODEL(), so most entries intentionally use a '?' wildcard.
fm_aqr_model_from_phy_id() {
	local id
	FM_AQR_MODEL=''
	fm_normalize_phy_id "$1" || return 1
	id=${FM_PHY_ID#0x}

	case "$id" in
		03a1b4a?) FM_AQR_MODEL='AQR105' ;;
		03a1b4d?) FM_AQR_MODEL='AQR106' ;;
		03a1b4e?) FM_AQR_MODEL='AQR107' ;;
		03a1b4b?) FM_AQR_MODEL='AQR405' ;;
		03a1b612) FM_AQR_MODEL='AQR111B0' ;;
		03a1b61?) FM_AQR_MODEL='AQR111' ;;
		03a1b66?) FM_AQR_MODEL='AQR112' ;;
		03a1b6f?) FM_AQR_MODEL='AQR412' ;;
		03a1b71?) FM_AQR_MODEL='AQR412C' ;;
		31c31c4?) FM_AQR_MODEL='AQR113' ;;
		31c31c1?) FM_AQR_MODEL='AQR113C' ;;
		31c31c2?) FM_AQR_MODEL='AQR114C' ;;
		31c31c6?) FM_AQR_MODEL='AQR115' ;;
		31c31c3?) FM_AQR_MODEL='AQR115C' ;;
		31c31cb?) FM_AQR_MODEL='AQR813' ;;
		*) return 1 ;;
	esac
	return 0
}

# Aquantia/Marvell PHY vendor fingerprints used by the upstream driver.
# This is a fallback for a future AQR model whose exact ID is not yet in
# the table above. It deliberately does not claim an exact model name.
fm_is_aquantia_phy_id() {
	local id
	fm_normalize_phy_id "$1" || return 1
	id=${FM_PHY_ID#0x}
	case "$id" in
		03a1b[4-7]??|31c31[c-f]??) return 0 ;;
		*) return 1 ;;
	esac
}

fm_extract_aqr_model_from_driver() {
	local driver="$1" model
	FM_AQR_MODEL=''
	model="$(printf '%s\n' "$driver" | sed -n 's/.*\(AQR[0-9][A-Za-z0-9_-]*\).*/\1/p')"
	[ -n "$model" ] || return 1
	FM_AQR_MODEL="$model"
	return 0
}

fm_read_phy_id_for_hwmon() {
	local h="$1" f
	FM_PHY_ID=''
	for f in \
		"$h/device/phy_id" \
		"$h/device/c45_phy_ids/mmd1_device_id" \
		"$h/device/c45_phy_ids/mmd3_device_id" \
		"$h/device/c45_phy_ids/mmd4_device_id"
	do
		[ -r "$f" ] || continue
		fm_read_text "$f" || continue
		fm_normalize_phy_id "$FM_TEXT" || continue
		return 0
	done
	return 1
}

fm_mdio_address_for_hwmon() {
	local h="$1" device base addr
	FM_MDIO_ADDRESS=''
	device="$(readlink -f "$h/device" 2>/dev/null)"
	[ -n "$device" ] || return 1
	base=${device##*/}
	case "$base" in
		*:* ) addr=${base##*:} ;;
		* ) return 1 ;;
	esac
	addr="$(printf '%s' "$addr" | tr 'A-F' 'a-f')"
	case "$addr" in
		[0-9a-f]) addr="0$addr" ;;
		[0-9a-f][0-9a-f]) ;;
		*) return 1 ;;
	esac
	FM_MDIO_ADDRESS="0x$addr"
	return 0
}

fm_of_path_for_hwmon() {
	local h="$1" path
	FM_OF_PATH=''
	path="$(readlink -f "$h/device/of_node" 2>/dev/null)"
	if [ -n "$path" ]; then
		case "$path" in
			"$DT_BASE"/*) FM_OF_PATH=/${path#"$DT_BASE"/} ;;
			*) FM_OF_PATH="$path" ;;
		esac
		return 0
	fi
	if fm_uevent_value "$h/device/uevent" OF_FULLNAME; then
		FM_OF_PATH="$FM_TEXT"
		return 0
	fi
	return 1
}

fm_attached_netdev_for_hwmon() {
	local h="$1" path
	FM_ATTACHED_NETDEV=''
	path="$(readlink -f "$h/device/attached_dev" 2>/dev/null)"
	[ -n "$path" ] || return 1
	FM_ATTACHED_NETDEV=${path##*/}
	return 0
}

# Prefer the conventional first temperature channel, but accept another
# standard hwmon temperature input if a future driver adds/reorders channels.
fm_temp_input_for_hwmon() {
	local h="$1" f
	FM_TEMP_INPUT=''
	if [ -r "$h/temp1_input" ]; then
		FM_TEMP_INPUT="$h/temp1_input"
		return 0
	fi
	for f in "$h"/temp*_input; do
		[ -r "$f" ] || continue
		FM_TEMP_INPUT="$f"
		return 0
	done
	return 1
}

fm_detect_aqr_hwmon() {
	local h driver_path driver_name driver_model id_model phy_id candidate score best_score
	local device_path of_path mdio_addr netdev method model temp_file devtype compatible
	local router_lower driver_vendor id_vendor identity_warning

	AQR_HWMON=''
	AQR_TEMP_INPUT=''
	AQR_MODEL=''
	AQR_DRIVER=''
	AQR_PHY_ID=''
	AQR_MDIO_ADDRESS=''
	AQR_OF_PATH=''
	AQR_DEVICE_PATH=''
	AQR_ATTACHED_NETDEV=''
	AQR_DETECTION_METHOD=''
	AQR_IDENTITY_WARNING=''
	AQR_CANDIDATE_COUNT=0
	best_score=-1

	fm_detect_router_model
	router_lower="$(printf '%s' "$ROUTER_MODEL" | tr 'A-Z' 'a-z')"

	for h in "$HWMON_CLASS_ROOT"/hwmon*; do
		[ -d "$h" ] || continue
		fm_temp_input_for_hwmon "$h" || continue
		temp_file="$FM_TEMP_INPUT"

		driver_path="$(readlink -f "$h/device/driver" 2>/dev/null)"
		driver_name=${driver_path##*/}
		if [ -z "$driver_name" ] && fm_uevent_value "$h/device/uevent" DRIVER; then
			driver_name="$FM_TEXT"
		fi

		driver_model=''
		if fm_extract_aqr_model_from_driver "$driver_name"; then
			driver_model="$FM_AQR_MODEL"
		fi

		phy_id=''
		id_model=''
		id_vendor=0
		if fm_read_phy_id_for_hwmon "$h"; then
			phy_id="$FM_PHY_ID"
			if fm_aqr_model_from_phy_id "$phy_id"; then
				id_model="$FM_AQR_MODEL"
			elif fm_is_aquantia_phy_id "$phy_id"; then
				id_vendor=1
			fi
		fi

		fm_attached_netdev_for_hwmon "$h" && netdev="$FM_ATTACHED_NETDEV" || netdev=''
		fm_of_path_for_hwmon "$h" && of_path="$FM_OF_PATH" || of_path=''
		fm_mdio_address_for_hwmon "$h" && mdio_addr="$FM_MDIO_ADDRESS" || mdio_addr=''
		device_path="$(readlink -f "$h/device" 2>/dev/null)"

		devtype=''
		fm_uevent_value "$h/device/uevent" DEVTYPE && devtype="$FM_TEXT"
		compatible=''
		if [ -r "$h/device/of_node/compatible" ]; then
			compatible="$(tr '\000' '\n' < "$h/device/of_node/compatible" 2>/dev/null)"
		elif fm_uevent_value "$h/device/uevent" OF_COMPATIBLE_0; then
			compatible="$FM_TEXT"
		fi

		candidate=0
		score=0
		method=''
		driver_vendor=0

		if [ -n "$id_model" ]; then
			candidate=1
			score=$((score + 90))
			method='known_phy_id'
		elif [ "$id_vendor" -eq 1 ]; then
			candidate=1
			score=$((score + 50))
			method='aq_vendor_phy_id'
		fi

		if [ -n "$driver_model" ]; then
			candidate=1
			score=$((score + 70))
			[ -n "$method" ] && method="$method+driver_model" || method='driver_model'
		fi

		case "$driver_name" in
			*Aquantia*)
				driver_vendor=1
				score=$((score + 35))
				[ -n "$method" ] && method="$method+aquantia_driver" || method='aquantia_driver'
				;;
			*Marvell*)
				driver_vendor=1
				score=$((score + 10))
				;;
		esac

		case "$netdev" in
			10g-copper|*10g*copper*)
				score=$((score + 100))
				[ -n "$method" ] && method="$method+10g_netdev" || method='10g_netdev'
				;;
		esac
		[ "$devtype" = 'PHY' ] && score=$((score + 10))
		case "$compatible" in
			*ethernet-phy-ieee802.3-c45*) score=$((score + 10)) ;;
		esac
		case "$mdio_addr" in 0x07|0x08) score=$((score + 10)) ;; esac

		# Last-resort RT-AX89X topology fallback. This deliberately requires
		# the known copper interface plus a PHY at one of the two board MDIO
		# addresses, so a future driver/vendor rename does not lose cooling.
		if [ "$candidate" -eq 0 ]; then
			case "$router_lower:$netdev:$devtype:$mdio_addr" in
				*rt-ax89x*:10g-copper:PHY:0x07|*rt-ax89x*:10g-copper:PHY:0x08)
					candidate=1
					score=$((score + 60))
					method='rt_ax89x_topology_fallback'
					;;
			esac
		fi

		# Aquantia-branded PHY hwmon is also accepted even if a future chip
		# has an unknown ID and no AQR token in the driver display name.
		if [ "$candidate" -eq 0 ] && [ "$driver_vendor" -eq 1 ] && [ "$devtype" = 'PHY' ]; then
			case "$driver_name" in
				*Aquantia*)
					candidate=1
					method='aquantia_driver_fallback'
					;;
			esac
		fi

		[ "$candidate" -eq 1 ] || continue
		AQR_CANDIDATE_COUNT=$((AQR_CANDIDATE_COUNT + 1))

		identity_warning=''
		if [ -n "$id_model" ]; then
			model="$id_model"
			if [ -n "$driver_model" ] && [ "$driver_model" != "$id_model" ]; then
				identity_warning="driver name says $driver_model but PHY ID maps to $id_model; PHY ID was preferred"
			fi
		elif [ -n "$driver_model" ]; then
			model="$driver_model"
		else
			model='AQ-family PHY (unknown model)'
		fi

		if [ "$score" -gt "$best_score" ]; then
			best_score="$score"
			AQR_HWMON="$h"
			AQR_TEMP_INPUT="$temp_file"
			AQR_DRIVER="$driver_name"
			AQR_PHY_ID="$phy_id"
			AQR_MDIO_ADDRESS="$mdio_addr"
			AQR_OF_PATH="$of_path"
			AQR_DEVICE_PATH="$device_path"
			AQR_ATTACHED_NETDEV="$netdev"
			AQR_DETECTION_METHOD="$method"
			AQR_MODEL="$model"
			AQR_IDENTITY_WARNING="$identity_warning"
		fi
	done

	[ -n "$AQR_HWMON" ]
}

fm_infer_router_revision() {
	local model="$AQR_MODEL" addr="$AQR_MDIO_ADDRESS" path="$AQR_OF_PATH" dev="$AQR_DEVICE_PATH" router_lower
	ROUTER_HW_REVISION='Unknown'
	ROUTER_PCB_REVISION='Unknown'
	ROUTER_REVISION_CONFIDENCE='none'
	ROUTER_REVISION_BASIS='No matching RT-AX89X PHY layout was identified'

	fm_detect_router_model
	router_lower="$(printf '%s' "$ROUTER_MODEL" | tr 'A-Z' 'a-z')"
	case "$router_lower" in
		*rt-ax89x*) ;;
		*)
			ROUTER_REVISION_BASIS="Hardware revision inference is only defined for Asus RT-AX89X (detected: $ROUTER_MODEL)"
			return 1
			;;
	esac

	# The combined RT-AX89X DTS uses the old hardware MDIO controller at
	# address 7 for PCB R1.00-R4.20 and a GPIO/bit-banged MDIO bus at
	# address 8 for PCB R5.00. B1/B2 are inferred from this runtime layout.
	if [ "$addr" = '0x08' ]; then
		case "$path $dev" in
			*'/mdio1/'*|*'/gpio-'*)
				ROUTER_HW_REVISION='B2 (inferred)'
				ROUTER_PCB_REVISION='R5.00'
				ROUTER_REVISION_CONFIDENCE='high'
				ROUTER_REVISION_BASIS="AQR PHY on GPIO MDIO address 0x08${model:+ ($model)}"
				return 0
				;;
		esac
	fi

	if [ "$addr" = '0x07' ]; then
		ROUTER_HW_REVISION='B1 (inferred)'
		ROUTER_PCB_REVISION='R1.00-R4.20'
		ROUTER_REVISION_CONFIDENCE='high'
		ROUTER_REVISION_BASIS="AQR PHY on legacy MDIO address 0x07${model:+ ($model)}"
		return 0
	fi

	case "$model" in
		AQR113C)
			ROUTER_HW_REVISION='B2 (inferred)'
			ROUTER_PCB_REVISION='R5.00'
			ROUTER_REVISION_CONFIDENCE='medium'
			ROUTER_REVISION_BASIS='Inferred from AQR113C model; MDIO layout was unavailable'
			;;
		AQR107|AQR113)
			ROUTER_HW_REVISION='B1 (inferred)'
			ROUTER_PCB_REVISION='R1.00-R4.20'
			ROUTER_REVISION_CONFIDENCE='medium'
			ROUTER_REVISION_BASIS="Inferred from $model model; MDIO layout was unavailable"
			;;
	esac
}

fm_detect_router_model() {
	ROUTER_MODEL='Asus RT-AX89X'
	if [ -r /tmp/sysinfo/model ]; then
		fm_read_text /tmp/sysinfo/model && [ -n "$FM_TEXT" ] && ROUTER_MODEL="$FM_TEXT"
	elif fm_read_dt_string "$DT_BASE/model"; then
		ROUTER_MODEL="$FM_TEXT"
	fi
}

fm_detect_cpu_hwmon_paths() {
	local h name path zone type
	CPU_HWMON_PATHS=''
	CPU_SENSOR_COUNT=0
	for h in "$HWMON_CLASS_ROOT"/hwmon*; do
		[ -d "$h" ] || continue
		[ -r "$h/temp1_input" ] || continue
		name="$(cat "$h/name" 2>/dev/null)"
		case "$name" in
			cpu[0-9]*_thermal|cluster_thermal|cpu_thermal)
				CPU_HWMON_PATHS="$CPU_HWMON_PATHS $h"
				CPU_SENSOR_COUNT=$((CPU_SENSOR_COUNT + 1))
				continue
				;;
		esac

		# Fallback to the thermal zone type if hwmon name formatting changes.
		path="$(readlink -f "$h" 2>/dev/null)"
		case "$path" in
			*/thermal_zone*/hwmon*)
				zone=${path%/hwmon*}
				type="$(cat "$zone/type" 2>/dev/null)"
				case "$type" in
					cpu[0-9]*-thermal|cluster-thermal|cpu-thermal)
						CPU_HWMON_PATHS="$CPU_HWMON_PATHS $h"
						CPU_SENSOR_COUNT=$((CPU_SENSOR_COUNT + 1))
						;;
				esac
				;;
		esac
	done
	[ "$CPU_SENSOR_COUNT" -gt 0 ]
}

fm_detect_fan_hwmon() {
	local h name path
	FAN_HWMON=''
	for h in "$HWMON_CLASS_ROOT"/hwmon*; do
		[ -d "$h" ] || continue
		[ -w "$h/fan1_target" ] || continue
		name="$(cat "$h/name" 2>/dev/null)"
		path="$(readlink -f "$h" 2>/dev/null)"
		case "$name:$path" in
			gpio_fan:*|*:*/gpio-fan/*) FAN_HWMON="$h"; return 0 ;;
		esac
	done
	return 1
}

fm_detect_wifi_hwmon() {
	local h path name phy
	WIFI0_HWMON=''
	WIFI1_HWMON=''
	for h in "$HWMON_CLASS_ROOT"/hwmon*; do
		[ -d "$h" ] || continue
		[ -r "$h/temp1_input" ] || continue
		path="$(readlink -f "$h" 2>/dev/null)"
		name="$(cat "$h/name" 2>/dev/null)"
		case "$path" in
			*/ieee80211/phy0/*) WIFI0_HWMON="$h" ;;
			*/ieee80211/phy1/*) WIFI1_HWMON="$h" ;;
		esac
		# Keep path matching primary; ath11k's hwmon name alone does not
		# identify which radio it belongs to.
		case "$name" in ath11k_hwmon) : ;; esac
	done
	[ -n "$WIFI0_HWMON" ] || [ -n "$WIFI1_HWMON" ]
}
