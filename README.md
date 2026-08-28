# PCIe NUMA Topology Analyzer

A Linux shell script that analyzes PCIe devices on a system and groups them by their NUMA (Non-Uniform Memory Access) node. This tool is useful for understanding system topology and optimizing performance by identifying which PCIe devices are local to which NUMA nodes.

## Features

- Lists physical PCIe devices (NVMe, NICs, GPUs, storage controllers, etc.) by default
- Automatically filters out infrastructure devices (bridges, IOMMU, system peripherals)
- Groups devices by their associated NUMA node
- Displays device information including PCI address and description
- Shows the bound kernel driver and kernel device names (e.g., `nvme0n1`, `ens1f0`, `sda`) for each device; flags devices with no driver bound
- Maps devices to their physical motherboard slot designation (e.g., `CPU SLOT3 PCI-E 4.0 X16`) using SMBIOS data when run as root
- Verbose mode shows PCIe link speed/width and flags links that trained below their maximum (`DEGRADED`)
- Provides summary statistics with filtered device count
- Colored output for better readability
- Multiple output modes (all, verbose, summary-only)

## Requirements

- Linux operating system with sysfs support
- Bash shell
- Optional: `lspci` utility for detailed device descriptions (part of `pciutils` package)
- Optional: `dmidecode` and root privileges for motherboard slot designations

## Installation

Simply clone this repository or download the script:

```bash
git clone <repository-url>
cd numatopo
chmod +x pcie-numa-analyzer.sh
```

## Usage

### Basic Usage

```bash
./pcie-numa-analyzer.sh
```

By default, this shows only physical/endpoint devices (NVMe drives, NICs, GPUs, storage controllers, USB controllers, etc.), filtering out infrastructure like bridges, IOMMU, and system peripherals.

### Command Line Options

- `-h, --help`: Display help message
- `-a, --all`: Show all devices including bridges and infrastructure
- `-b, --by-slot`: Group devices by physical motherboard slot — a top-down view of the system. Each slot heading notes its NUMA node; onboard devices (no slot) are grouped by NUMA node in a section below
- `-v, --verbose`: Show verbose output with additional device details (vendor/device IDs, class codes, PCIe link speed/width)
- `-n, --no-color`: Disable colored output (useful for piping to files)
- `-s, --summary`: Show only summary statistics

### Examples

**Physical devices only (default):**
```bash
./pcie-numa-analyzer.sh
```

**All devices including bridges:**
```bash
./pcie-numa-analyzer.sh -a
```

**Verbose output with all device details:**
```bash
./pcie-numa-analyzer.sh -v
```

**Summary only:**
```bash
./pcie-numa-analyzer.sh -s
```

**Without colors (for logging):**
```bash
./pcie-numa-analyzer.sh -n > pcie-topology.txt
```

## Understanding the Output

### Device Information

Each PCIe device is displayed with:
- **PCI Address**: The bus:device.function address (e.g., `0000:00:1f.2`)
- **Description**: Human-readable device name (from lspci)
- **Driver and kernel names**: The bound kernel driver and associated kernel device names, e.g. `[nvme: nvme3n1]`, `[tg3: eno1]`; a yellow `[no driver]` marks devices with nothing bound
- **Motherboard slot**: The physical slot designation from SMBIOS, e.g. `[slot: CPU SLOT3 PCI-E 4.0 X16]` — matching what is printed on the motherboard silkscreen. Shown only for devices in slots the BIOS reports (onboard devices have no slot). Requires `dmidecode` and root; silently omitted otherwise. All functions of a multi-function card (e.g., both ports of a dual-port NIC) receive the same slot tag. Bifurcated slots (e.g., an x16 riser carrying multiple NVMe drives) are handled by joining the kernel's per-port slot numbers from `/sys/bus/pci/slots` with the SMBIOS slot IDs, so every device in the slot is labeled even though SMBIOS records only one bus address per slot. When a bifurcated port has no BIOS slot record of its own, the slot is inferred from topology: a bifurcated slot spans consecutive sibling root ports (functions of one parent device) starting at the port SMBIOS's Bus Address names, and the record's Data Bus Width bounds how many x4 devices fit. Each slot label extends upward from its anchor port to unlabeled devices of the same class within that lane budget, stopping at any port that already carries a label or a different device class. Connectors the BIOS describes only via PCIe Slot Capabilities (e.g., SlimSAS ports) get a raw `Slot N` label for their own bus — those firmware-internal numbers are never joined to SMBIOS slot IDs, since they need not match
- **Onboard designation**: Devices named in SMBIOS type 41 (Onboard Devices Extended Information) are tagged e.g. `[onboard: ASPEED Video AST2500]`; disabled entries are ignored
- **Vendor/Device IDs**: In verbose mode (e.g., `0x8086:0x9d03`)
- **Class Code**: In verbose mode (e.g., `0x010601` for SATA controller)
- **Link speed/width**: In verbose mode, e.g. `[16.0GT/s x8]`; a link that trained below its maximum is flagged as `DEGRADED(max ...)`. Note: a DEGRADED flag can be transient on power-managed (ASPM) links — verify under I/O load before reseating hardware

### NUMA Nodes

- **NUMA Node N**: Devices are grouped under their respective NUMA node number (0, 1, 2, etc.)
- **NUMA Node N/A**: Devices that don't have NUMA information or are on systems without NUMA support

### Device Filtering

By default, the script hides infrastructure devices based on PCI base class codes:

| Base Class | Description | Filtered |
|---|---|---|
| `0x05` | Memory controller | Yes |
| `0x06` | Bridge (host, PCI-PCI, ISA, etc.) | Yes |
| `0x08` | System peripheral (IOMMU, PIC, DMA) | Yes |
| `0x10` | Encryption controller (e.g., AMD PTDMA/PSP) | Yes |
| `0x13` | Non-Essential Instrumentation | Yes |
| All others | Storage, network, display, USB, etc. | No (shown) |

Use `-a` to see all devices including infrastructure.

### Example Output

From an AMD EPYC Milan server with 4 NUMA nodes:

```
========================================
  PCIe Devices Grouped by NUMA Node
========================================

NUMA Node: 0
  0000:c1:00.0 - Non-Volatile memory controller: Micron Technology Inc 7500 PRO NVMe SSD
  0000:c2:00.0 - Non-Volatile memory controller: Micron Technology Inc 7500 PRO NVMe SSD
  0000:c3:00.0 - Non-Volatile memory controller: Intel Corporation PCIe Data Center SSD
  0000:c4:00.0 - Non-Volatile memory controller: Intel Corporation PCIe Data Center SSD

NUMA Node: 2
  0000:81:00.0 - Non-Volatile memory controller: Intel Corporation PCIe Data Center SSD
  0000:82:00.0 - Non-Volatile memory controller: Intel Corporation PCIe Data Center SSD
  0000:83:00.0 - Non-Volatile memory controller: Micron Technology Inc 7500 PRO NVMe SSD
  0000:84:00.0 - Non-Volatile memory controller: Micron Technology Inc 7500 PRO NVMe SSD

NUMA Node: 4
  0000:41:00.0 - Non-Volatile memory controller: Intel Corporation PCIe Data Center SSD
  0000:47:00.0 - USB controller: ASMedia Technology Inc. ASM1042A USB 3.0 Host Controller
  0000:49:00.0 - VGA compatible controller: ASPEED Technology, Inc. ASPEED Graphics Family
  0000:4b:00.0 - Ethernet controller: Broadcom Inc. NetXtreme BCM5720 Gigabit Ethernet PCIe
  0000:4b:00.1 - Ethernet controller: Broadcom Inc. NetXtreme BCM5720 Gigabit Ethernet PCIe
  0000:4e:00.0 - SATA controller: Advanced Micro Devices, Inc. [AMD] FCH SATA Controller

NUMA Node: 6
  0000:01:00.0 - Non-Volatile memory controller: Intel Corporation PCIe Data Center SSD
  0000:02:00.0 - Non-Volatile memory controller: Intel Corporation PCIe Data Center SSD
  0000:06:00.3 - USB controller: Advanced Micro Devices, Inc. [AMD] Starship USB 3.0 Host Controller

========================================
  Summary
========================================
NUMA Node 0: 4 device(s)
NUMA Node 2: 4 device(s)
NUMA Node 4: 6 device(s)
NUMA Node 6: 3 device(s)
Total PCIe devices: 17
  (95 infrastructure device(s) hidden, use -a to show all)
```

## How It Works

The script reads information from the Linux sysfs virtual filesystem:

1. **Device enumeration**: Scans `/sys/bus/pci/devices/` for all PCIe devices
2. **NUMA node detection**: Reads `/sys/bus/pci/devices/<device>/numa_node` for each device
3. **Infrastructure filtering**: Checks the PCI base class code from `/sys/bus/pci/devices/<device>/class` to filter out bridges and system peripherals (unless `-a` is used)
4. **Device details**: Retrieves vendor, device, and class information from sysfs
5. **Description lookup**: Uses `lspci` if available for human-readable device names
6. **Grouping and display**: Organizes devices by NUMA node and displays them

## Understanding NUMA

NUMA (Non-Uniform Memory Access) is a memory architecture used in multi-processor systems where memory access time depends on the memory location relative to a processor. PCIe devices are typically attached to specific NUMA nodes, and for optimal performance:

- Processes should run on CPUs in the same NUMA node as the devices they interact with
- Memory allocations should be from the same NUMA node as the accessing CPU/device
- Network and storage workloads benefit significantly from NUMA-aware placement

## Troubleshooting

### Permission Denied Errors

If you get permission denied errors, the script may need elevated privileges:

```bash
sudo ./pcie-numa-analyzer.sh
```

### No NUMA Information

If all devices show "NUMA Node N/A":
- Your system may not have NUMA configured (common on single-socket systems)
- NUMA support may be disabled in BIOS
- The kernel may not have NUMA support enabled

### Missing lspci

If device descriptions show as "Unknown (lspci not available)":
- Install pciutils: `sudo apt-get install pciutils` (Debian/Ubuntu) or `sudo yum install pciutils` (RHEL/CentOS)

## Use Cases

- **Performance optimization**: Identify which devices are local to which NUMA nodes for workload placement
- **System auditing**: Document PCIe device topology
- **Capacity planning**: Understand device distribution across NUMA nodes
- **Troubleshooting**: Diagnose performance issues related to cross-NUMA access
- **HPC and high-performance networking**: Optimize device-to-CPU affinity

## License

This project is provided as-is for system administration and performance optimization purposes.

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.
