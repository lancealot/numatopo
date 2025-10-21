# PCIe NUMA Topology Analyzer

A Linux shell script that analyzes PCIe devices on a system and groups them by their NUMA (Non-Uniform Memory Access) node. This tool is useful for understanding system topology and optimizing performance by identifying which PCIe devices are local to which NUMA nodes.

## Features

- Lists all PCIe devices on the system
- Groups devices by their associated NUMA node
- Displays device information including PCI address and description
- Provides summary statistics
- Colored output for better readability
- Multiple output modes (standard, verbose, summary-only)

## Requirements

- Linux operating system with sysfs support
- Bash shell
- Optional: `lspci` utility for detailed device descriptions (part of `pciutils` package)

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

This will display all PCIe devices grouped by NUMA node with basic information.

### Command Line Options

- `-h, --help`: Display help message
- `-v, --verbose`: Show verbose output with additional device details (vendor/device IDs, class codes)
- `-n, --no-color`: Disable colored output (useful for piping to files)
- `-s, --summary`: Show only summary statistics

### Examples

**Basic listing:**
```bash
./pcie-numa-analyzer.sh
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
- **Vendor/Device IDs**: In verbose mode (e.g., `0x8086:0x9d03`)
- **Class Code**: In verbose mode (e.g., `0x010601` for SATA controller)

### NUMA Nodes

- **NUMA Node N**: Devices are grouped under their respective NUMA node number (0, 1, 2, etc.)
- **NUMA Node N/A**: Devices that don't have NUMA information or are on systems without NUMA support

### Example Output

```
========================================
  PCIe Devices Grouped by NUMA Node
========================================

NUMA Node: 0
  0000:00:00.0 - Host bridge: Intel Corporation Device 1234
  0000:00:1f.2 - SATA controller: Intel Corporation Device 5678
  0000:01:00.0 - Network controller: Intel Corporation Ethernet Controller

NUMA Node: 1
  0000:80:00.0 - PCI bridge: Intel Corporation Device abcd
  0000:81:00.0 - Network controller: Mellanox Technologies MT27800

========================================
  Summary
========================================
NUMA Node 0: 3 device(s)
NUMA Node 1: 2 device(s)
Total PCIe devices: 5
```

## How It Works

The script reads information from the Linux sysfs virtual filesystem:

1. **Device enumeration**: Scans `/sys/bus/pci/devices/` for all PCIe devices
2. **NUMA node detection**: Reads `/sys/bus/pci/devices/<device>/numa_node` for each device
3. **Device details**: Retrieves vendor, device, and class information from sysfs
4. **Description lookup**: Uses `lspci` if available for human-readable device names
5. **Grouping and display**: Organizes devices by NUMA node and displays them

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
