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
    -v, --verbose       Show verbose output with additional device details
    -n, --no-color      Disable colored output
    -s, --summary       Show summary statistics only

EXAMPLES:
    $(basename "$0")                    # Physical devices only (default)
    $(basename "$0") -a                 # All devices including bridges
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
declare -A dmi_slot_ids
if command -v dmidecode >/dev/null 2>&1; then
    dmi_slots=$(dmidecode -t 9 2>/dev/null) || dmi_slots=""
    slot_name=""
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"  # trim leading whitespace
        case "$line" in
            Handle\ *)
                slot_name=""
                ;;
            Designation:*)
                slot_name="${line#*: }"
                ;;
            ID:*)
                if [ -n "$slot_name" ]; then
                    dmi_slot_ids["${line#*: }"]="$slot_name"
                fi
                ;;
            Bus\ Address:*)
                slot_addr="${line#*: }"
                slot_addr="${slot_addr,,}"
                if [ -n "$slot_name" ]; then
                    pci_slots["${slot_addr%.*}"]="$slot_name"
                fi
                ;;
        esac
    done <<< "$dmi_slots"
fi

# A bifurcated slot (e.g. an x16 riser carrying multiple NVMe drives) puts
# each drive on its own bus behind its own root port, but DMI records only
# one Bus Address per slot. The kernel's per-port slot info under
# /sys/bus/pci/slots (from PCIe Slot Capabilities / ACPI) covers every
# port, all reporting the same physical slot number - join those numbers
# with the DMI slot IDs to label every device in the slot.
slots_dir="${PCI_SLOTS_DIR:-/sys/bus/pci/slots}"
for slot_path in "$slots_dir"/*; do
    [ -r "$slot_path/address" ] || continue
    slot_addr=$(cat "$slot_path/address" 2>/dev/null) || continue
    slot_addr="${slot_addr,,}"
    [[ $slot_addr =~ ^[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}$ ]] || continue
    slot_num="${slot_path##*/}"
    slot_num="${slot_num%%-*}"  # duplicate slot numbers get -1, -2 suffixes
    slot_name="${dmi_slot_ids[$slot_num]:-Slot $slot_num}"
    # A direct DMI Bus Address entry wins when both name the same address
    if [ -z "${pci_slots[$slot_addr]:-}" ]; then
        pci_slots[$slot_addr]="$slot_name"
    fi
done

# Declare associative arrays
declare -A numa_devices
declare -A numa_count
filtered_count=0

# Scan all PCIe devices
echo -e "${CYAN}Scanning PCIe devices...${NC}"
echo

for device in /sys/bus/pci/devices/*; do
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

        # Build device info string
        if [ "$VERBOSE" = true ]; then
            device_info="  ${GREEN}${pci_addr}${NC} - ${vendor_device} [${device_class}] - ${description}${dev_tag}${link_tag}${slot_tag}"
        else
            device_info="  ${GREEN}${pci_addr}${NC} - ${description}${dev_tag}${slot_tag}"
        fi

        # Add to the appropriate NUMA node group
        if [ -z "${numa_devices[$numa_node]}" ]; then
            numa_devices[$numa_node]="$device_info"
            numa_count[$numa_node]=1
        else
            numa_devices[$numa_node]="${numa_devices[$numa_node]}"$'\n'"$device_info"
            numa_count[$numa_node]=$((numa_count[$numa_node] + 1))
        fi
    fi
done

# Sort NUMA nodes
numa_nodes=($(for key in "${!numa_devices[@]}"; do echo "$key"; done | sort -n))

# Display results
if [ "$SUMMARY_ONLY" = false ]; then
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
