# Azure VM Zonal Copy Script

A PowerShell script that creates a copy of an Azure VM in a target availability zone within a new resource group. The source VM and all its resources remain untouched.

## Overview

This script safely copies an Azure VM (regional or zonal) to a specified availability zone in a **different** resource group. It performs a non-destructive operation—your source VM is stopped for consistent snapshots but never modified or deleted.

### What the Script Does

1. **Validates** the source VM, target resource group, zone availability, and encryption status
2. **Checks for Azure Disk Encryption (ADE)** and blocks if detected (ADE-encrypted disks cannot be copied)
3. **Stops** the source VM for consistent snapshots
4. **Creates incremental snapshots** of all disks (OS and data disks)
5. **Creates new zonal disks** from the snapshots in the target resource group
6. **Optionally converts disk SKUs** during migration (e.g., Premium to Standard)
7. **Creates a new NIC** with all configurations copied from the source
8. **Creates the new VM** in the target availability zone
9. **Cleans up** temporary snapshots
10. **Reports** any VM extensions that need manual installation

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
    [-NewVMName <new-vm-name>] [-TargetOsDiskSku <sku>] [-TargetDataDiskSku <sku>] [-WhatIf]
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `ResourceGroupName` | Yes | The resource group name of the source VM |
| `VMName` | Yes | The name of the source VM to copy |
| `TargetResourceGroupName` | Yes | The resource group where new resources will be created (must be different from source) |
| `TargetZone` | Yes | The target availability zone (1, 2, or 3) |
| `NewVMName` | No | Name for the new VM (defaults to same name as source) |
| `TargetOsDiskSku` | No | SKU for the new OS disk (defaults to source SKU) |
| `TargetDataDiskSku` | No | SKU for all new data disks (defaults to each source disk's SKU) |
| `WhatIf` | No | Preview mode—shows what would happen without making changes |

### Valid Disk SKU Values

- `Standard_LRS` - Standard HDD
- `StandardSSD_LRS` - Standard SSD (locally redundant)
- `StandardSSD_ZRS` - Standard SSD (zone redundant)
- `Premium_LRS` - Premium SSD (locally redundant)
- `Premium_ZRS` - Premium SSD (zone redundant)
- `PremiumV2_LRS` - Premium SSD v2 (requires `Caching='None'`)
- `UltraSSD_LRS` - Ultra Disk (requires `Caching='None'`)

> **Note:** When converting to `PremiumV2_LRS` or `UltraSSD_LRS`, the source disk must already have `Caching='None'` configured.

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

**Copy and convert OS disk to Premium SSD:**

```powershell
.\move-vmtozone.ps1 -ResourceGroupName "my-source-rg" -VMName "my-vm" `
    -TargetResourceGroupName "my-target-rg" -TargetZone 2 -TargetOsDiskSku Premium_LRS
```

**Copy and convert all disks to Standard SSD:**

```powershell
.\move-vmtozone.ps1 -ResourceGroupName "my-source-rg" -VMName "my-vm" `
    -TargetResourceGroupName "my-target-rg" -TargetZone 2 `
    -TargetOsDiskSku StandardSSD_LRS -TargetDataDiskSku StandardSSD_LRS
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

## Features

### Preserved Configurations

The script preserves the following from the source VM:

- **Disk configurations:** SKU type (or converted), size, IOPS, throughput, tier, logical sector size
- **Disk Encryption Set (DES):** Server-side encryption with customer-managed keys
- **Encryption at Host:** Host-based encryption setting
- **NIC configurations:** Subnet, NSG, DNS settings, accelerated networking, IP forwarding
- **Load balancer associations:** Backend pools, inbound NAT rules
- **Application Gateway:** Backend pool associations
- **Application Security Groups**
- **VM settings:** Size, boot diagnostics, license type, tags
- **Security profile:** Trusted Launch, vTPM, Secure Boot
- **Identity:** System-assigned and user-assigned managed identities
- **Spot VM settings:** Priority, eviction policy, max price
- **Proximity Placement Group:** If compatible with target zone

### Disk SKU Conversion

You can convert disk SKUs during migration:

- Convert Standard HDD to Premium SSD for better performance
- Convert Premium SSD to Standard SSD for cost savings
- Convert to Zone-Redundant Storage (ZRS) for higher availability
- Each disk type (OS vs data) can be converted independently

### Special Disk Handling

- **Ultra Disks & Premium SSD v2:** Uses instant access snapshots for faster disk creation
- **Caching validation:** Ensures Premium V2 and Ultra disks have `None` caching (Azure requirement)

### Security Validations

- **Azure Disk Encryption (ADE):** The script detects and blocks VMs encrypted with ADE (BitLocker/dm-crypt). ADE-encrypted disks cannot be copied to a new VM without becoming inaccessible.
- **Encryption at Host:** This setting IS preserved and copied to the new VM.

### Proximity Placement Group (PPG) Support

The script intelligently handles PPGs:

- ✅ Uses source PPG if it's compatible with the target zone
- ✅ Uses source PPG if not yet pinned to any zone
- ⚠️ Skips PPG assignment if pinned to a different zone
- ⚠️ Skips PPG assignment if running regional VMs would cause conflicts

## Limitations

| Limitation | Details |
|------------|----------|
| **Single NIC only** | VMs with multiple NICs are not supported |
| **Different resource group required** | Target RG must be different from source RG |
| **New IP address** | New VM will have a different IP than the source |
| **No Public IP copy** | Public IPs are not copied (must be attached manually) |
| **No VM extensions** | Extensions are not automatically installed on the new VM |
| **No ADE support** | VMs with Azure Disk Encryption (BitLocker/dm-crypt) are blocked |

## IP Address Handling

The new VM will receive a **different IP address** assigned dynamically by Azure:

- The source NIC keeps its IP address (source resources are NOT modified)
- The new NIC gets a new dynamic IP from the same subnet
- You may need to update DNS records or firewall rules after migration

> **Note:** IP preservation is not possible without modifying the source NIC. Since this script prioritizes keeping source resources unchanged, the new VM will have a different IP.

## Output

The script provides detailed progress information and a final summary showing:

- Source VM and resource details (unchanged)
- New VM and resource details (created)
- Disk SKUs (original and converted if applicable)
- List of extensions that need manual installation
- Important notes about the operation

## After Running the Script

1. **Verify the new VM** is working correctly
2. **Install any required extensions** on the new VM
3. **Attach Public IPs** if needed
4. **Update DNS records or firewall rules** with the new IP address
5. **Delete the source VM** and its resources when satisfied

## Troubleshooting

### Common Issues

**"No Azure context set"**
- Run `Set-AzContext -SubscriptionId "your-subscription-id"` before the script

**"Target resource group must be different from source"**
- Create a new resource group for the target VM

**"VM size not available in zone"**
- Choose a different target zone or resize the VM before migration

**"Azure Disk Encryption (ADE) detected"**
- ADE-encrypted disks cannot be copied. Options:
  - Disable ADE on the source VM first (Windows data disks, Linux data disks)
  - For Linux OS disks with ADE, create a new VM with a fresh OS disk
  - Consider migrating to "Encryption at Host" instead of ADE

**"Caching must be 'None' for Premium V2 / Ultra disks"**
- Change the source disk caching to `None` before running the script, or choose a different target SKU

**"Snapshot timeout"**
- For large disks, the script may take longer; it will retry automatically

## License

This script is provided as-is. Use at your own risk and always test in a non-production environment first.

## Contributing

Feel free to submit issues and pull requests to improve this script.
