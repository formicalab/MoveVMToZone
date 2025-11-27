# Azure VM Zonal Copy Script

A PowerShell script that creates a copy of an Azure VM in a target availability zone within a new resource group. The source VM and all its resources remain untouched.

## Overview

This script safely copies an Azure VM (regional or zonal) to a specified availability zone in a **different** resource group. It performs a non-destructive operation—your source VM is stopped for consistent snapshots but never modified or deleted.

### What the Script Does

1. **Validates** the source VM, target resource group, and zone availability
2. **Stops** the source VM for consistent snapshots
3. **Creates incremental snapshots** of all disks (OS and data disks)
4. **Creates new zonal disks** from the snapshots in the target resource group
5. **Creates a new NIC** with all configurations copied from the source
6. **Creates the new VM** in the target availability zone
7. **Cleans up** temporary snapshots
8. **Reports** any VM extensions that need manual installation

## Requirements

- **PowerShell 7.0+**
- **Azure PowerShell Modules:**
  - `Az.Compute`
  - `Az.Network`
  - `Az.Resources`
- An active Azure context (set via `Set-AzContext`)

## Installation

1. Clone or download this repository
2. Ensure you have the required PowerShell modules installed:

```powershell
Install-Module -Name Az.Compute, Az.Network, Az.Resources -Scope CurrentUser
```

## Usage

### Basic Syntax

```powershell
.\move-vmtozone.ps1 -ResourceGroupName <source-rg> -VMName <vm-name> `
    -TargetResourceGroupName <target-rg> -TargetZone <1|2|3> `
    [-NewVMName <new-vm-name>] [-WhatIf]
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `ResourceGroupName` | Yes | The resource group name of the source VM |
| `VMName` | Yes | The name of the source VM to copy |
| `TargetResourceGroupName` | Yes | The resource group where new resources will be created (must be different from source) |
| `TargetZone` | Yes | The target availability zone (1, 2, or 3) |
| `NewVMName` | No | Name for the new VM (defaults to same name as source) |
| `WhatIf` | No | Preview mode—shows what would happen without making changes |

### Examples

**Copy a VM to zone 2 (same name, different resource group):**

```powershell
.\move-vmtozone.ps1 -ResourceGroupName "my-source-rg" -VMName "my-vm" `
    -TargetResourceGroupName "my-target-rg" -TargetZone 2
```

**Copy with a new name and preview changes first:**

```powershell
.\move-vmtozone.ps1 -ResourceGroupName "my-source-rg" -VMName "my-vm" `
    -TargetResourceGroupName "my-target-rg" -TargetZone 1 -NewVMName "my-vm-zone1" -WhatIf
```

### Prerequisites

Before running the script:

1. **Set your Azure context:**

   ```powershell
   Set-AzContext -SubscriptionId "your-subscription-id"
   ```

2. **Ensure the target resource group exists:**

   ```powershell
   New-AzResourceGroup -Name "my-target-rg" -Location "eastus"
   ```

3. **Ensure the source NIC has Dynamic IP allocation.** If it has a static IP, change it first:

   ```powershell
   $nic = Get-AzNetworkInterface -Name "my-nic" -ResourceGroupName "my-source-rg"
   $nic.IpConfigurations[0].PrivateIpAllocationMethod = 'Dynamic'
   $nic.IpConfigurations[0].PrivateIpAddress = $null
   $nic | Set-AzNetworkInterface
   ```

## Features

### Preserved Configurations

The script preserves the following from the source VM:

- **Disk configurations:** SKU type, size, IOPS, throughput, tier, logical sector size
- **Disk encryption:** Disk Encryption Set (DES) settings
- **NIC configurations:** Subnet, NSG, DNS settings, accelerated networking, IP forwarding
- **Load balancer associations:** Backend pools, inbound NAT rules
- **Application Gateway:** Backend pool associations
- **Application Security Groups**
- **VM settings:** Size, boot diagnostics, license type, tags
- **Security profile:** Trusted Launch, vTPM, Secure Boot
- **Identity:** System-assigned and user-assigned managed identities
- **Spot VM settings:** Priority, eviction policy, max price
- **Proximity Placement Group:** If compatible with target zone

### Special Disk Handling

- **Ultra Disks & Premium SSD v2:** Uses instant access snapshots for faster disk creation
- **Caching validation:** Ensures Premium V2 and Ultra disks have `None` caching (Azure requirement)

### Proximity Placement Group (PPG) Support

The script intelligently handles PPGs:

- ✅ Uses source PPG if it's compatible with the target zone
- ✅ Uses source PPG if not yet pinned to any zone
- ⚠️ Skips PPG assignment if pinned to a different zone
- ⚠️ Skips PPG assignment if running regional VMs would cause conflicts

## Limitations

| Limitation | Details |
|------------|---------|
| **Single NIC only** | VMs with multiple NICs are not supported |
| **Different resource group required** | Target RG must be different from source RG |
| **Dynamic IP required** | Source NIC must have Dynamic IP allocation |
| **New IP address** | The new NIC will receive a different IP from Azure |
| **No Public IP copy** | Public IPs are not copied (must be attached manually) |
| **No VM extensions** | Extensions are not automatically installed on the new VM |

## Output

The script provides detailed progress information and a final summary showing:

- Source VM and resource details (unchanged)
- New VM and resource details (created)
- List of extensions that need manual installation
- Important notes about the operation

## After Running the Script

1. **Verify the new VM** is working correctly
2. **Install any required extensions** on the new VM
3. **Attach Public IPs** if needed
4. **Update DNS records** or load balancer configurations as needed
5. **Delete the source VM** and its resources when satisfied

## Troubleshooting

### Common Issues

**"No Azure context set"**
- Run `Set-AzContext -SubscriptionId "your-subscription-id"` before the script

**"Target resource group must be different from source"**
- Create a new resource group for the target VM

**"VM size not available in zone"**
- Choose a different target zone or resize the VM before migration

**"Source NIC must have Dynamic IP allocation"**
- Change the source NIC to use Dynamic IP (see Prerequisites)

**"Snapshot timeout"**
- For large disks, the script may take longer; it will retry automatically

## License

This script is provided as-is. Use at your own risk and always test in a non-production environment first.

## Contributing

Feel free to submit issues and pull requests to improve this script.
