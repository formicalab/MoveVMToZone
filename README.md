# Azure VM Zonal Copy Script

A PowerShell script that creates a copy of an Azure VM in a target availability zone using VM restore points. The source VM and all its resources remain untouched.

## Overview

This script safely copies an Azure VM (regional or zonal) to a specified availability zone. The target can be the same or a **different** resource group. It performs a non-destructive operation—your source VM is stopped for consistent restore points but never modified or deleted.

### What the Script Does

1. **Validates** the source VM, target resource group, zone availability, and encryption status
2. **Displays disk inventory** showing SKU, size, zone status, and encryption type for all disks
3. **Checks VM restore point compatibility** and warns about unsupported disk types
4. **Checks for Azure Disk Encryption (ADE)** and blocks if detected (ADE-encrypted disks cannot be copied)
5. **Validates Proximity Placement Group** constraints and blocks if incompatible
6. **Shows physical zone mapping** (logical zone → physical datacenter)
7. **Stops** the source VM for consistent restore points
8. **Creates a VM restore point** with all disks (multi-disk consistent)
9. **Creates new zonal disks** from the disk restore points in the target resource group
10. **Optionally converts disk SKUs** during migration (e.g., Premium to Standard)
11. **Creates a new NIC** with all configurations copied from the source
12. **Creates the new VM** in the target availability zone
13. **Cleans up** the temporary restore point collection
14. **Reports** any VM extensions that need manual installation

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
    -TargetZone <1|2|3> [-TargetResourceGroupName <target-rg>] `
    [-NewVMName <new-vm-name>] [-TargetOsDiskSku <sku>] [-TargetDataDiskSku <sku>] `
    [-ParallelDiskCreation <1-16>] [-WhatIf]
```

### Parameters

| Parameter | Required | Description |
|-----------|----------|-------------|
| `ResourceGroupName` | Yes | The resource group name of the source VM |
| `VMName` | Yes | The name of the source VM to copy |
| `TargetZone` | Yes | The target availability zone (1, 2, or 3) |
| `TargetResourceGroupName` | No | The resource group for new resources (defaults to source RG) |
| `NewVMName` | Conditional | Name for the new VM. **Required** if target RG equals source RG |
| `TargetOsDiskSku` | No | SKU for the new OS disk (defaults to source SKU) |
| `TargetDataDiskSku` | No | SKU for all new data disks (defaults to each source disk's SKU) |
| `ParallelDiskCreation` | No | Number of data disks to create in parallel (1-16, default: 1) |
| `WhatIf` | No | Preview mode—shows what would happen without making changes |

### Valid Disk SKU Values

- `Standard_LRS` - Standard HDD
- `StandardSSD_LRS` - Standard SSD (locally redundant)
- `StandardSSD_ZRS` - Standard SSD (zone redundant)
- `Premium_LRS` - Premium SSD (locally redundant)
- `Premium_ZRS` - Premium SSD (zone redundant)
- `PremiumV2_LRS` - Premium SSD v2 (requires `Caching='None'`)
- `UltraSSD_LRS` - Ultra Disk (requires `Caching='None'`)

> **Note:** When converting to `PremiumV2_LRS` or `UltraSSD_LRS`, the script automatically uses Azure defaults for IOPS and throughput (source values are not copied since they may not be valid for the new SKU). The new VM will have `Caching='None'` set for these disks.

### Examples

**Copy a VM to zone 2 in the same resource group:**

```powershell
.\move-vmtozone.ps1 -ResourceGroupName "my-rg" -VMName "my-vm" `
    -TargetZone 2 -NewVMName "my-vm-zone2"
```

**Copy a VM to zone 2 in a different resource group (same name):**

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

**Copy a VM with many data disks using parallel creation:**

```powershell
.\move-vmtozone.ps1 -ResourceGroupName "my-rg" -VMName "my-vm-16disks" `
    -TargetZone 2 -NewVMName "my-vm-zone2" -ParallelDiskCreation 8
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

### Disk Inventory Display

The script displays a detailed inventory of all disks before migration:

```
  DISK INVENTORY
  ──────────────────────────────────────────────────────────────────────────────
  OS Disk:
    my-vm-osdisk
      SKU: Premium_LRS | Size: 128 GB | Zone 1 | Encryption: SSE+PMK
  Data Disks (3):
    LUN 0: my-vm-data01 | Premium_LRS | 512 GB | Zone 1 | SSE+CMK
    LUN 1: my-vm-data02 | StandardSSD_LRS | 256 GB | Regional | SSE+PMK
    LUN 2: my-vm-data03 | Premium_LRS | 1000 GB | Zone 1 | SSE+CMK
```

- **SKU**: Disk storage type
- **Size**: Disk capacity in GB
- **Zone**: Shows `Zone 1/2/3` for zonal disks or `Regional` for non-zonal disks
- **Encryption**: `SSE+PMK` (Platform-Managed Keys) or `SSE+CMK` (Customer-Managed Keys via Disk Encryption Set)

### Physical Zone Mapping

The script displays the physical zone that corresponds to your target logical zone:

```
  ZONE MAPPING INFORMATION
  Target Logical Zone  : 2
  Physical Zone        : eastus-az2
  Location             : eastus
```

> **Note:** Physical zones are shared across subscriptions with the same zone mapping. Different subscriptions may have different logical-to-physical zone mappings.

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
- **Resource cleanup:** NIC and all disks are configured with `DeleteOption=Delete` so they are automatically deleted when the VM is deleted

### Disk SKU Conversion

You can convert disk SKUs during migration:

- Convert Standard HDD to Premium SSD for better performance
- Convert Premium SSD to Standard SSD for cost savings
- Convert to Zone-Redundant Storage (ZRS) for higher availability
- Each disk type (OS vs data) can be converted independently

### Special Disk Handling

- **VM Restore Points:** Uses crash-consistent restore points for multi-disk consistency
- **Caching validation:** Ensures Premium V2 and Ultra disks have `None` caching (Azure requirement)
- **SKU conversion:** When converting to Premium SSD v2 or Ultra SSD, IOPS/throughput values are not copied from source (Azure applies appropriate defaults for the new SKU)
- **Parallel creation:** Use `-ParallelDiskCreation` to speed up migrations with many data disks

### VM Restore Point Limitations

The script uses VM restore points instead of individual snapshots. This provides better multi-disk consistency but has some limitations:

| Disk Type | Crash Consistent | Application Consistent |
|-----------|-----------------|----------------------|
| Standard HDD/SSD | ✅ Supported | ✅ Supported |
| Premium SSD | ✅ Supported | ✅ Supported |
| Premium SSD v2 | ❌ Not supported | ⚠️ May work |
| Ultra SSD | ❌ Not supported | ⚠️ May work |
| Write-accelerated disks | ❌ Not supported | ⚠️ May work |
| Ephemeral OS disks | ❌ Not supported | ❌ Not supported |
| Shared disks | ❌ Not supported | ❌ Not supported |

> **Note:** The script checks for these limitations before proceeding and will warn or stop if your VM uses unsupported disk types. For more details, see [VM restore points limitations](https://learn.microsoft.com/azure/virtual-machines/virtual-machines-create-restore-points#limitations).

### Security Validations

- **Azure Disk Encryption (ADE):** The script detects and blocks VMs encrypted with ADE (BitLocker/dm-crypt). ADE-encrypted disks cannot be copied to a new VM without becoming inaccessible.
- **Encryption at Host:** This setting IS preserved and copied to the new VM.
- **Disk Encryption Sets (SSE+CMK):** Server-side encryption with customer-managed keys is fully preserved.

### Proximity Placement Group (PPG) Support

The script enforces strict PPG constraints to prevent deployment failures:

| PPG Scenario | Behavior |
|--------------|----------|
| PPG is compatible with target zone | ✅ Uses source PPG |
| PPG not yet pinned to any zone | ✅ Uses source PPG (becomes pinned to target zone) |
| PPG pinned to a different zone | ❌ **Script stops** — Use `-TargetZone` matching the PPG zone |
| PPG has running regional VMs | ❌ **Script stops** — Stop those VMs first, then retry |

> **Note:** Unlike previous versions that would skip PPG assignment with a warning, the script now stops and requires you to resolve PPG conflicts before proceeding.

## Limitations

| Limitation | Details |
|------------|----------|
| **Single NIC only** | VMs with multiple NICs are not supported |
| **New IP address** | New VM will have a different IP than the source |
| **No Public IP copy** | Public IPs are not copied (must be attached manually) |
| **No VM extensions** | Extensions are not automatically installed on the new VM |
| **No ADE support** | VMs with Azure Disk Encryption (BitLocker/dm-crypt) are blocked |
| **No Ultra SSD/Premium v2** | Crash-consistent restore points don't support these disk types |
| **No Ephemeral/Shared disks** | Ephemeral OS disks and shared disks are not supported |
| **Same RG requires new name** | If target RG equals source RG, NewVMName must be different |
| **PPG constraints enforced** | Script stops if PPG is incompatible with target zone |

## IP Address Handling

The new VM will receive a **different IP address** assigned dynamically by Azure:

- The source NIC keeps its IP address (source resources are NOT modified)
- The new NIC gets a new dynamic IP from the same subnet
- You may need to update DNS records or firewall rules after migration

> **Note:** IP preservation is not possible without modifying the source NIC. Since this script prioritizes keeping source resources unchanged, the new VM will have a different IP.

## Output

The script provides detailed progress information including:

- **Disk inventory** with SKU, size, zone, and encryption details
- **Physical zone mapping** showing which datacenter the logical zone maps to
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

**"NewVMName must be different from source VMName"**
- When using the same resource group, you must specify a different name via `-NewVMName`

**"VM is not compatible with VM restore points"**
- Your VM has disks that don't support restore points (Ultra SSD, Premium SSD v2, shared disks, etc.)
- Consider using individual snapshots for these VMs or changing disk types

**"VM size not available in zone"**
- Choose a different target zone or resize the VM before migration

**"Azure Disk Encryption (ADE) detected"**
- ADE-encrypted disks cannot be copied. Options:
  - Disable ADE on the source VM first (Windows data disks, Linux data disks)
  - For Linux OS disks with ADE, create a new VM with a fresh OS disk
  - Consider migrating to "Encryption at Host" instead of ADE

**"Caching must be 'None' for Premium V2 / Ultra disks"**
- Change the source disk caching to `None` before running the script, or choose a different target SKU

**"Restore point creation timeout"**
- For large disks, the restore point may take longer; it will retry automatically

**"PPG is pinned to zone X but target is zone Y"**
- Change `-TargetZone` to match the PPG's pinned zone, or remove the VM from the PPG before migration

**"PPG has running regional VMs"**
- Stop all regional VMs in the PPG before running the script, then retry

**"Could not determine physical zone mapping"**
- This is informational only and doesn't block the migration
- May occur if the region doesn't support zone mappings or due to API limitations

## License

This script is provided as-is. Use at your own risk and always test in a non-production environment first.

## Contributing

Feel free to submit issues and pull requests to improve this script.
