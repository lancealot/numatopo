#!/bin/bash

#
# PCIe NUMA Node Analyzer
#
# This script analyzes PCIe devices on a Linux system and groups them by NUMA node.
# It provides information about device location, vendor, and device type.
#

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Function to print usage
print_usage() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Analyze PCIe devices and group them by NUMA node.

OPTIONS:
    -h, --help          Show this help message
    -a, --all           Show all devices including bridges and infrastructure
    -b, --by-slot       Group devices by physical slot (top-down view);
                        onboard devices are grouped by NUMA node below
    -v, --verbose       Show verbose output with additional device details
    -n, --no-color      Disable colored output
    -s, --summary       Show summary statistics only

EXAMPLES:
    $(basename "$0")                    # Physical devices only (default)
    $(basename "$0") -a                 # All devices including bridges
    $(basename "$0") -b                 # Grouped by physical slot
    $(basename "$0") -v                 # Verbose physical devices
    $(basename "$0") -a -v              # Verbose all devices
    $(basename "$0") -s                 # Summary only

EOF
}

# Parse command line arguments
VERBOSE=false
NO_COLOR=false
SUMMARY_ONLY=false
SHOW_ALL=false
BY_SLOT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            print_usage
            exit 0
            ;;
        -a|--all)
            SHOW_ALL=true
            shift
            ;;
        -b|--by-slot)
            BY_SLOT=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -n|--no-color)
            NO_COLOR=true
            shift
            ;;
        -s|--summary)
            SUMMARY_ONLY=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Disable colors if requested
if [ "$NO_COLOR" = true ]; then
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
fi

# Check if running with sufficient permissions
if [ ! -r /sys/bus/pci/devices ]; then
    echo -e "${RED}Error: Cannot read /sys/bus/pci/devices${NC}"
    echo "This script requires read access to sysfs. Try running with sudo."
    exit 1
fi

# Function to get device description from lspci
get_device_description() {
    local pci_addr=$1
    if command -v lspci &> /dev/null; then
        lspci -s "$pci_addr" 2>/dev/null | cut -d' ' -f2- || echo "Unknown"
    else
        echo "Unknown (lspci not available)"
    fi
}

# Function to get vendor and device IDs
get_vendor_device_info() {
    local device_path=$1
    local vendor_id=""
    local device_id=""
    local vendor_name=""
    local device_name=""

    if [ -f "$device_path/vendor" ]; then
        vendor_id=$(cat "$device_path/vendor" 2>/dev/null)
    fi

    if [ -f "$device_path/device" ]; then
        device_id=$(cat "$device_path/device" 2>/dev/null)
    fi

    echo "${vendor_id:-Unknown}:${device_id:-Unknown}"
}

# Function to get device class
get_device_class() {
    local device_path=$1
    if [ -f "$device_path/class" ]; then
        cat "$device_path/class" 2>/dev/null || echo "Unknown"
    else
        echo "Unknown"
    fi
}

# Function to check if a device class is infrastructure (filtered by default)
# Base class is the top byte of the 24-bit class code (e.g., 0x060000 -> 06)
is_infrastructure_device() {
    local class_code=$1
    local base_class="${class_code:2:2}"
    case "$base_class" in
        06) return 0 ;;  # Bridge (host, PCI-PCI, ISA, etc.)
        08) return 0 ;;  # System peripheral (IOMMU, PIC, DMA, timer)
        05) return 0 ;;  # Memory controller
        10) return 0 ;;  # Encryption controller (e.g., AMD PTDMA/PSP)
        13) return 0 ;;  # Non-Essential Instrumentation
        *)  return 1 ;;
    esac
}

# Function to get PCIe link speed/width for a device
# Prints e.g. "16.0GT/s x8", with DEGRADED(...) appended when the link
# trained below its maximum. Prints nothing when link info is unavailable.
get_link_info() {
    local d=$1 cs="" cw="" ms="" mw=""
    [ -r "$d/current_link_speed" ] || return 0
    cs=$(cat "$d/current_link_speed" 2>/dev/null) || cs=""
    cw=$(cat "$d/current_link_width" 2>/dev/null) || cw=""
    ms=$(cat "$d/max_link_speed" 2>/dev/null) || ms=""
    mw=$(cat "$d/max_link_width" 2>/dev/null) || mw=""
    # Values can read "Unknown speed" or width 0 when the link is down
    [[ $cs =~ ^[0-9] && $cw =~ ^[1-9][0-9]*$ ]] || return 0
    local out="${cs%% GT*}GT/s x${cw}"
    # Integer parts of PCIe speeds (2,5,8,16,32,64) are all distinct, so
    # integer comparison is enough to detect a downtrained link
    if [[ $ms =~ ^[0-9] && $mw =~ ^[1-9][0-9]*$ ]] && \
       { [ "${cs%%.*}" -lt "${ms%%.*}" ] || [ "$cw" -lt "$mw" ]; }; then
        out="$out DEGRADED(max ${ms%% GT*}GT/s x${mw})"
    fi
    printf '%s' "$out"
    return 0
}

# Map PCI address -> kernel device names (NICs, disks, NVMe namespaces).
# The greedy match pins the LAST PCI address in the resolved sysfs path,
# i.e. the endpoint itself rather than an upstream bridge.
declare -A pci_ifnames
add_ifname() {
    local path name=${1##*/}
    path=$(readlink -f "$1" 2>/dev/null) || return 0
    if [[ $path =~ .*/([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])/ ]]; then
        local addr=${BASH_REMATCH[1]}
        pci_ifnames[$addr]="${pci_ifnames[$addr]:+${pci_ifnames[$addr]} }$name"
    fi
    return 0
}

for entry in /sys/class/net/*; do
    [ -e "$entry" ] || continue
    add_ifname "$entry"
done
for entry in /sys/class/block/*; do
    [ -e "$entry" ] || continue
    [ -e "$entry/partition" ] && continue  # skip sda1, nvme0n1p2, ...
    add_ifname "$entry"
done

# Map PCI address -> motherboard slot designation, from SMBIOS type 9
# (System Slot Information) via dmidecode. Requires root; skipped silently
# when dmidecode is unavailable or unprivileged. DMI reports function .0 of
# the slot while multi-function cards occupy .1, .2, ... as well, so keys
# drop the PCI function - every function of a card shares its slot.
declare -A pci_slots
declare -A dmi_anchor_width
if command -v dmidecode >/dev/null 2>&1; then
    dmi_slots=$(dmidecode -t 9 2>/dev/null) || dmi_slots=""
    slot_name=""
    slot_width=""
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
        case "$line" in
            Handle\ *)
                slot_name=""
                slot_width=""
                ;;
            Designation:*)
                slot_name="${line#*: }"
                ;;
            Data\ Bus\ Width:*)
                # e.g. "8x or x8" -> 8 lanes
                if [[ ${line#*: } =~ x([0-9]+)$ ]]; then
                    slot_width="${BASH_REMATCH[1]}"
                fi
                ;;
            Bus\ Address:*)
                slot_addr="${line#*: }"
                slot_addr="${slot_addr,,}"
                if [ -n "$slot_name" ]; then
                    pci_slots["${slot_addr%.*}"]="$slot_name"
                    dmi_anchor_width["${slot_addr%.*}"]="${slot_width:-0}"
                fi
                ;;
        esac
    done <<< "$dmi_slots"
fi

# Onboard device names from SMBIOS type 41 (Onboard Devices Extended
# Information), e.g. the BMC's ASPEED VGA. Keyed by full function address;
# disabled entries (which often carry phantom bus addresses) are skipped.
declare -A pci_onboard
if command -v dmidecode >/dev/null 2>&1; then
    dmi_onboard=$(dmidecode -t 41 2>/dev/null) || dmi_onboard=""
    ob_name=""
    ob_enabled=true
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        case "$line" in
            Handle\ *)
                ob_name=""
                ob_enabled=true
                ;;
            Reference\ Designation:*)
                ob_name="${line#*: }"
                ;;
            Status:*Disabled*)
                ob_enabled=false
                ;;
            Bus\ Address:*)
                ob_addr="${line#*: }"
                ob_addr="${ob_addr,,}"
                if [ -n "$ob_name" ] && [ "$ob_enabled" = true ]; then
                    pci_onboard["$ob_addr"]="$ob_name"
                fi
                ;;
        esac
    done <<< "$dmi_onboard"
fi

# The kernel's per-port slot info under /sys/bus/pci/slots (from PCIe Slot
# Capabilities) also covers connectors DMI does not describe, e.g. SlimSAS
# ports. Its slot numbers are firmware-internal and do NOT reliably match
# DMI slot IDs (observed: SlimSAS ports numbered 2 and 27 alongside a DMI
# "CPU SLOT2"), so they are used only as a raw fallback label for their
# own bus, never joined to DMI designations.
slots_dir="${PCI_SLOTS_DIR:-/sys/bus/pci/slots}"
for slot_path in "$slots_dir"/*; do
    [ -r "$slot_path/address" ] || continue
    slot_addr=$(cat "$slot_path/address" 2>/dev/null) || continue
    slot_addr="${slot_addr,,}"
    [[ $slot_addr =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}$ ]] || continue
    slot_num="${slot_path##*/}"
    slot_num="${slot_num%%-*}"  # duplicate slot numbers get -1, -2 suffixes
    # A direct DMI Bus Address entry wins when both name the same address
    if [ -z "${pci_slots[$slot_addr]:-}" ]; then
        pci_slots[$slot_addr]="Slot $slot_num"
    fi
done

pci_devices_dir="${PCI_DEVICES_DIR:-/sys/bus/pci/devices}"

# Map each endpoint bus to its parent root port (device + function) and
# its device class, for the slot propagation below.
declare -A bus_parent
declare -A bus_portfn
declare -A bus_class
declare -A port_bus
for device in "$pci_devices_dir"/*; do
    [ -d "$device" ] || continue
    dev_addr=$(basename "$device")
    bus_key="${dev_addr%.*}"
    [ -n "${bus_parent[$bus_key]:-}" ] && continue
    real=$(readlink -f "$device" 2>/dev/null) || continue
    if [[ $real =~ /([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2})\.([0-7])/[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7]$ ]]; then
        bus_parent[$bus_key]="${BASH_REMATCH[1]}"
        bus_portfn[$bus_key]="${BASH_REMATCH[2]}"
        class_key=$(get_device_class "$device")
        bus_class[$bus_key]="${class_key:2:4}"  # base+sub class, 0108 = NVMe
        port_bus["${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"]="$bus_key"
    fi
done

# A bifurcated slot spans consecutive sibling root ports (functions of one
# parent device) starting at the port DMI's Bus Address names, and its
# "Data Bus Width" bounds how many x4 devices fit in it. Extend each DMI
# slot label upward from its anchor port to unlabeled same-class devices
# within that lane budget, stopping at any port that already carries a
# label or holds a different device class. Kernel SltCap labels never
# propagate: those connectors (e.g. SlimSAS x4) carry one bus each.
for anchor in "${!dmi_anchor_width[@]}"; do
    parent="${bus_parent[$anchor]:-}"
    [ -n "$parent" ] || continue
    budget=$(( ${dmi_anchor_width[$anchor]} / 4 - 1 ))
    [ "$budget" -gt 0 ] || continue
    anchor_class="${bus_class[$anchor]:-}"
    for (( fn = ${bus_portfn[$anchor]} + 1; fn <= 7; fn++ )); do
        sibling="${port_bus[${parent}.${fn}]:-}"
        [ -n "$sibling" ] || continue                # gap in port numbering
        [ -z "${pci_slots[$sibling]:-}" ] || break   # next slot/connector
        [ "${bus_class[$sibling]:-}" = "$anchor_class" ] || break
        pci_slots[$sibling]="${pci_slots[$anchor]}"
        budget=$(( budget - 1 ))
        [ "$budget" -gt 0 ] || break
    done
done

# Declare associative arrays
declare -A numa_devices
declare -A numa_count
declare -A slot_devices
declare -A slot_numa
filtered_count=0

# Scan all PCIe devices
echo -e "${CYAN}Scanning PCIe devices...${NC}"
echo

for device in "$pci_devices_dir"/*; do
    if [ -d "$device" ]; then
        pci_addr=$(basename "$device")
        numa_node=-1

        # Get NUMA node
        if [ -f "$device/numa_node" ]; then
            numa_node=$(cat "$device/numa_node" 2>/dev/null || echo "-1")
        fi

        # Get device class and filter infrastructure devices by default
        device_class=$(get_device_class "$device")
        if [ "$SHOW_ALL" = false ] && is_infrastructure_device "$device_class"; then
            filtered_count=$((filtered_count + 1))
            continue
        fi

        # Get device information
        vendor_device=$(get_vendor_device_info "$device")
        description=$(get_device_description "$pci_addr")

        # Bound kernel driver and kernel device names (nvme0n1, ens1f0, ...)
        driver=""
        if [ -L "$device/driver" ]; then
            driver=$(basename "$(readlink "$device/driver")") || driver=""
        fi
        kernel_names="${pci_ifnames[$pci_addr]:-}"
        if [ -n "$driver" ]; then
            dev_tag=" ${CYAN}[${driver}${kernel_names:+: ${kernel_names}}]${NC}"
        else
            dev_tag=" ${YELLOW}[no driver]${NC}"
        fi

        # PCIe link speed/width (verbose only)
        link_tag=""
        if [ "$VERBOSE" = true ]; then
            link_info=$(get_link_info "$device") || link_info=""
            if [ -n "$link_info" ]; then
                link_tag=" [${link_info/DEGRADED/${RED}DEGRADED}${NC}]"
            fi
        fi

        # Motherboard slot designation (keyed without the PCI function)
        slot_tag=""
        slot_name="${pci_slots[${pci_addr%.*}]:-}"
        if [ -n "$slot_name" ]; then
            slot_tag=" ${BLUE}[slot: ${slot_name}]${NC}"
        fi

        # Onboard device designation from SMBIOS type 41
        onboard_tag=""
        if [ -z "$slot_name" ] && [ -n "${pci_onboard[$pci_addr]:-}" ]; then
            onboard_tag=" ${BLUE}[onboard: ${pci_onboard[$pci_addr]}]${NC}"
        fi

        # Build device info string (in by-slot mode the slot is the group
        # heading, so the per-line slot tag is dropped as redundant)
        if [ "$VERBOSE" = true ]; then
            device_info="  ${GREEN}${pci_addr}${NC} - ${vendor_device} [${device_class}] - ${description}${dev_tag}${link_tag}"
        else
            device_info="  ${GREEN}${pci_addr}${NC} - ${description}${dev_tag}"
        fi
        if [ "$BY_SLOT" = false ]; then
            device_info="${device_info}${slot_tag}"
        fi
        device_info="${device_info}${onboard_tag}"

        # Count every device toward its NUMA node for the summary
        numa_count[$numa_node]=$((${numa_count[$numa_node]:-0} + 1))

        # Group under the slot (by-slot mode) or under the NUMA node
        if [ "$BY_SLOT" = true ] && [ -n "$slot_name" ]; then
            if [ -z "${slot_devices[$slot_name]:-}" ]; then
                slot_devices[$slot_name]="$device_info"
            else
                slot_devices[$slot_name]="${slot_devices[$slot_name]}"$'\n'"$device_info"
            fi
            case " ${slot_numa[$slot_name]:-} " in
                *" ${numa_node} "*) : ;;
                *) slot_numa[$slot_name]="${slot_numa[$slot_name]:-}${slot_numa[$slot_name]:+ }${numa_node}" ;;
            esac
        else
            if [ -z "${numa_devices[$numa_node]:-}" ]; then
                numa_devices[$numa_node]="$device_info"
            else
                numa_devices[$numa_node]="${numa_devices[$numa_node]}"$'\n'"$device_info"
            fi
        fi
    fi
done

# Sort NUMA nodes (from numa_count, which covers slotted devices too)
numa_nodes=()
if [ ${#numa_count[@]} -gt 0 ]; then
    mapfile -t numa_nodes < <(printf '%s\n' "${!numa_count[@]}" | sort -n)
fi

# Display results
if [ "$SUMMARY_ONLY" = false ] && [ "$BY_SLOT" = true ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  PCIe Devices Grouped by Slot${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo

    if [ ${#slot_devices[@]} -gt 0 ]; then
        mapfile -t slot_names < <(printf '%s\n' "${!slot_devices[@]}" | sort -V)
        for slot_name in "${slot_names[@]}"; do
            slot_nodes="${slot_numa[$slot_name]// /, }"
            slot_nodes="${slot_nodes//-1/N\/A}"
            echo -e "${YELLOW}Slot: ${slot_name} [NUMA Node: ${slot_nodes}]${NC}"
            echo -e "${slot_devices[$slot_name]}"
            echo
        done
    else
        echo -e "${YELLOW}No devices with slot information found.${NC}"
        echo
    fi

    if [ ${#numa_devices[@]} -gt 0 ]; then
        echo -e "${BLUE}Onboard / No Slot Info (grouped by NUMA node)${NC}"
        echo
        for numa_node in "${numa_nodes[@]}"; do
            [ -n "${numa_devices[$numa_node]:-}" ] || continue
            if [ "$numa_node" = "-1" ]; then
                echo -e "${YELLOW}NUMA Node: N/A (No NUMA or shared)${NC}"
            else
                echo -e "${YELLOW}NUMA Node: ${numa_node}${NC}"
            fi
            echo -e "${numa_devices[$numa_node]}"
            echo
        done
    fi
elif [ "$SUMMARY_ONLY" = false ]; then
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}  PCIe Devices Grouped by NUMA Node${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo

    for numa_node in "${numa_nodes[@]}"; do
        if [ "$numa_node" = "-1" ]; then
            echo -e "${YELLOW}NUMA Node: N/A (No NUMA or shared)${NC}"
        else
            echo -e "${YELLOW}NUMA Node: ${numa_node}${NC}"
        fi
        echo -e "${numa_devices[$numa_node]}"
        echo
    done
fi

# Display summary
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  Summary${NC}"
echo -e "${BLUE}========================================${NC}"

total_devices=0
for numa_node in "${numa_nodes[@]}"; do
    count=${numa_count[$numa_node]}
    total_devices=$((total_devices + count))

    if [ "$numa_node" = "-1" ]; then
        echo -e "NUMA Node ${YELLOW}N/A${NC}: $count device(s)"
    else
        echo -e "NUMA Node ${YELLOW}${numa_node}${NC}: $count device(s)"
    fi
done

echo -e "${CYAN}Total PCIe devices: ${total_devices}${NC}"
if [ "$SHOW_ALL" = false ] && [ "$filtered_count" -gt 0 ]; then
    echo -e "${YELLOW}  (${filtered_count} infrastructure device(s) hidden, use -a to show all)${NC}"
fi

# Check if system has NUMA
if [ ${#numa_nodes[@]} -eq 1 ] && [ "${numa_nodes[0]}" = "-1" ]; then
    echo
    echo -e "${YELLOW}Note: This system does not appear to have NUMA nodes configured,${NC}"
    echo -e "${YELLOW}or NUMA information is not available for PCIe devices.${NC}"
fi

echo
