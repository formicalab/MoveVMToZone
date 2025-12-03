<#
.SYNOPSIS
    Creates a copy of an Azure VM in a target availability zone using VM restore points.

.DESCRIPTION
    This script creates a zonal copy of an Azure VM (regional or zonal) into a specified
    availability zone. The target can be the same or a different resource group. 
    The source VM and all its resources remain untouched. The script:
    - Creates a VM restore point collection and restore point (multi-disk consistent)
    - Creates new zonal disks from disk restore points in the target resource group
    - Creates a new NIC with all configurations copied from the source
    - Creates the new VM in the target resource group

    IMPORTANT: This script does NOT delete or modify any source resources.
    If the target resource group is the same as the source (or not specified),
    the new VM name (NewVMName) MUST be different from the source VM name.
    
    PREREQUISITE: Set your Azure context before running this script using:
    Set-AzContext -SubscriptionId "your-subscription-id"

.PARAMETER ResourceGroupName
    The resource group name of the source VM.

.PARAMETER VMName
    The name of the source VM to copy.

.PARAMETER TargetResourceGroupName
    Optional. The resource group where the new VM and all resources will be created.
    If not specified, defaults to the source resource group.
    If the target is the same as the source, NewVMName must be different from the source VM name.

.PARAMETER TargetZone
    The target availability zone (1, 2, or 3).

.PARAMETER NewVMName
    Optional. The name for the new VM. 
    If target RG is different from source, defaults to the same name as the source VM.
    If target RG is the same as source (or not specified), this parameter is REQUIRED
    and must be different from the source VM name.

.PARAMETER TargetOsDiskSku
    Optional. The SKU for the target OS disk. If not specified, uses the same SKU as the source.
    Valid values: Standard_LRS, StandardSSD_LRS, StandardSSD_ZRS, Premium_LRS, Premium_ZRS, PremiumV2_LRS, UltraSSD_LRS
    Note: PremiumV2_LRS and UltraSSD_LRS only support Caching='None'. If converting to these SKUs,
    the source disk must already have Caching='None'.

.PARAMETER TargetDataDiskSku
    Optional. The SKU for all target data disks. If not specified, each data disk uses the same SKU as its source.
    Valid values: Standard_LRS, StandardSSD_LRS, StandardSSD_ZRS, Premium_LRS, Premium_ZRS, PremiumV2_LRS, UltraSSD_LRS
    Note: PremiumV2_LRS and UltraSSD_LRS only support Caching='None'. If converting to these SKUs,
    all source data disks must already have Caching='None'.

.PARAMETER ParallelDiskCreation
    Optional. Number of data disks to create in parallel (1-16). Default is 1 (sequential).
    Setting this to a higher value (e.g., 4-8) can significantly speed up migration for VMs with many data disks.
    Each parallel disk creation uses a separate Azure API call.

.PARAMETER WhatIf
    Optional. If specified, shows what would happen without making any changes.

.EXAMPLE
    .\move-vmtozone.ps1 -ResourceGroupName "my-rg" -VMName "my-vm" -TargetZone 2 -NewVMName "my-vm-zone2"
    # Creates 'my-vm-zone2' in same RG 'my-rg' in zone 2

.EXAMPLE
    .\move-vmtozone.ps1 -ResourceGroupName "my-source-rg" -VMName "my-vm" `
        -TargetResourceGroupName "my-target-rg" -TargetZone 2
    # Creates 'my-vm' in 'my-target-rg' in zone 2 (same VM name, different RG)

.EXAMPLE
    .\move-vmtozone.ps1 -ResourceGroupName "my-source-rg" -VMName "my-vm" `
        -TargetResourceGroupName "my-target-rg" -TargetZone 1 -NewVMName "my-vm-new" -WhatIf
    # Creates 'my-vm-new' in 'my-target-rg' in zone 1 with WhatIf preview

.EXAMPLE
    .\move-vmtozone.ps1 -ResourceGroupName "my-rg" -VMName "my-vm-16disks" `
        -TargetZone 2 -NewVMName "my-vm-zone2" -ParallelDiskCreation 8
    # Creates VM copy with 8 data disks created in parallel for faster migration

.NOTES
    Requires: PowerShell 7.0+, Az.Compute, Az.Network, Az.Resources modules
    
    IP ADDRESS HANDLING:
    - The new NIC will be assigned a NEW dynamic IP address by Azure
    - The source NIC keeps its IP (source resources are NOT modified)
    - You may need to update DNS records or firewall rules after migration
    
    VM RESTORE POINTS LIMITATIONS:
    - Ultra disks, Premium SSD v2 disks are NOT supported for crash consistency mode
    - Write-accelerated disks are NOT supported for crash consistency mode
    - Ephemeral OS disks and shared disks are NOT supported
    - Maximum 500 restore points can be retained per VM
    - Concurrent creation of restore points for a VM is not supported
    - VMs in VMSS with Uniform orchestration are not supported
    - Application-consistent restore points require VSS (Windows) or pre/post scripts (Linux)
    
    GENERAL LIMITATIONS:
    - VMs with multiple NICs are not supported
    - If target RG equals source RG, NewVMName must be different from VMName
    - New VM will have a DIFFERENT IP address than the source
    - VM extensions are NOT automatically installed on the new VM
    - Proximity Placement Groups: If the source VM is in a PPG, the script enforces PPG constraints:
      * If PPG has running regional VMs: Script stops. Stop those VMs first, then retry.
      * If PPG is pinned to a different zone: Script stops. Use -TargetZone matching the PPG zone.
#>

#Requires -Version 7.0
#Requires -Modules Az.Compute, Az.Network, Az.Resources

[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VMName,
    
    [Parameter(Mandatory = $false)]
    [string]$TargetResourceGroupName,
    
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, 3)]
    [int]$TargetZone,
    
    [Parameter(Mandatory = $false)]
    [string]$NewVMName,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('Standard_LRS', 'StandardSSD_LRS', 'StandardSSD_ZRS', 'Premium_LRS', 'Premium_ZRS', 'PremiumV2_LRS', 'UltraSSD_LRS')]
    [string]$TargetOsDiskSku,
    
    [Parameter(Mandatory = $false)]
    [ValidateSet('Standard_LRS', 'StandardSSD_LRS', 'StandardSSD_ZRS', 'Premium_LRS', 'Premium_ZRS', 'PremiumV2_LRS', 'UltraSSD_LRS')]
    [string]$TargetDataDiskSku,
    
    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 16)]
    [int]$ParallelDiskCreation = 1
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Helper Functions

function Write-StepHeader {
    <#
    .SYNOPSIS
        Writes a formatted step header to the console.
    #>
    param([string]$StepNumber, [string]$Title)
    Write-Host "`n$('=' * 80)" -ForegroundColor Cyan
    Write-Host "STEP $StepNumber : $Title" -ForegroundColor Cyan
    Write-Host "$('=' * 80)" -ForegroundColor Cyan
}

function Write-Success {
    <#
    .SYNOPSIS
        Writes a success message in green.
    #>
    param([string]$Message)
    Write-Host "[SUCCESS] $Message" -ForegroundColor Green
}

function Write-Info {
    <#
    .SYNOPSIS
        Writes an info message in cyan.
    #>
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Cyan
}

function Write-Detail {
    <#
    .SYNOPSIS
        Writes a detail message in gray with indentation.
    #>
    param([string]$Message)
    Write-Host "  $Message" -ForegroundColor Gray
}

function Get-PhysicalZone {
    <#
    .SYNOPSIS
        Gets the physical availability zone mapped to a logical zone for the current subscription and location.
    .DESCRIPTION
        Uses the Azure List Locations API to retrieve the availability zone mappings between logical
        and physical zones for the current subscription. This helps identify which physical datacenter
        corresponds to a logical zone number.
    .PARAMETER Location
        The Azure region location (e.g., 'eastus', 'westeurope').
    .PARAMETER LogicalZone
        The logical availability zone number (1, 2, or 3).
    .OUTPUTS
        String containing the physical zone identifier, or $null if mapping cannot be determined.
    .EXAMPLE
        Get-PhysicalZone -Location 'eastus' -LogicalZone 2
        # Returns something like 'eastus-az2' or the physical zone ID
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Location,
        
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 3)]
        [int]$LogicalZone
    )
    
    try {
        $subscriptionId = (Get-AzContext).Subscription.Id
        $response = Invoke-AzRestMethod -Method GET -Path "/subscriptions/$subscriptionId/locations?api-version=2022-12-01"
        
        if ($response.StatusCode -ne 200) {
            Write-Warning "Failed to retrieve location information. Status code: $($response.StatusCode)"
            return $null
        }
        
        $locations = ($response.Content | ConvertFrom-Json).value
        
        # Find the location (normalize to lowercase for comparison)
        $locationInfo = $locations | Where-Object { 
            $_.name -eq $Location.ToLower() -or 
            $_.displayName -eq $Location 
        }
        
        if (-not $locationInfo) {
            Write-Warning "Location '$Location' not found in subscription locations."
            return $null
        }
        
        if (-not $locationInfo.availabilityZoneMappings) {
            Write-Warning "No availability zone mappings found for location '$Location'."
            return $null
        }
        
        # Find the mapping for the specified logical zone
        $zoneMapping = $locationInfo.availabilityZoneMappings | Where-Object { 
            $_.logicalZone -eq $LogicalZone.ToString() 
        }
        
        if (-not $zoneMapping) {
            Write-Warning "No mapping found for logical zone $LogicalZone in location '$Location'."
            return $null
        }
        
        return $zoneMapping.physicalZone
    }
    catch {
        Write-Warning "Error retrieving physical zone mapping: $($_.Exception.Message)"
        return $null
    }
}

function Get-VMDiskInfo {
    <#
    .SYNOPSIS
        Gets disk information including SKU and encryption settings from the source VM.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine]$VM
    )
    
    # Validate VM storage profile
    if ($null -eq $VM.StorageProfile) {
        throw "VM StorageProfile is null. Cannot retrieve disk information."
    }
    
    if ($null -eq $VM.StorageProfile.OsDisk -or [string]::IsNullOrEmpty($VM.StorageProfile.OsDisk.Name)) {
        throw "VM OS disk information is missing or invalid."
    }
    
    # Get OS disk details
    $osDisk = Get-AzDisk -ResourceGroupName $VM.ResourceGroupName -DiskName $VM.StorageProfile.OsDisk.Name -ErrorAction Stop
    if ($null -eq $osDisk) {
        throw "Could not retrieve OS disk '$($VM.StorageProfile.OsDisk.Name)' from resource group '$($VM.ResourceGroupName)'"
    }
    
    $osDiskInfo = @{
        Name                 = $VM.StorageProfile.OsDisk.Name
        Caching              = if ($VM.StorageProfile.OsDisk.Caching) { $VM.StorageProfile.OsDisk.Caching.ToString() } else { 'None' }
        OsType               = if ($VM.StorageProfile.OsDisk.OsType) { $VM.StorageProfile.OsDisk.OsType.ToString() } else { 'Windows' }
        Sku                  = $osDisk.Sku.Name
        DiskSizeGB           = $osDisk.DiskSizeGB
        DiskIOPSReadWrite    = $osDisk.DiskIOPSReadWrite
        DiskMBpsReadWrite    = $osDisk.DiskMBpsReadWrite
        Tier                 = $osDisk.Tier
        LogicalSectorSize    = if ($osDisk.CreationData) { $osDisk.CreationData.LogicalSectorSize } else { $null }
        DiskEncryptionSetId  = $osDisk.Encryption?.DiskEncryptionSetId
        Zones                = $osDisk.Zones
        Tags                 = $osDisk.Tags
    }
    
    # Get data disk details
    $dataDisksInfo = @()
    if ($VM.StorageProfile.DataDisks -and $VM.StorageProfile.DataDisks.Count -gt 0) {
        foreach ($dataDisk in $VM.StorageProfile.DataDisks) {
            if ([string]::IsNullOrEmpty($dataDisk.Name)) {
                Write-Warning "Skipping data disk at LUN $($dataDisk.Lun) - disk name is empty"
                continue
            }
            
            $disk = Get-AzDisk -ResourceGroupName $VM.ResourceGroupName -DiskName $dataDisk.Name -ErrorAction SilentlyContinue
            if ($null -eq $disk) {
                Write-Warning "Could not retrieve data disk '$($dataDisk.Name)' - skipping"
                continue
            }
            
            $dataDisksInfo += @{
                Name                 = $dataDisk.Name
                Lun                  = $dataDisk.Lun
                Caching              = if ($dataDisk.Caching) { $dataDisk.Caching.ToString() } else { 'None' }
                Sku                  = $disk.Sku.Name
                DiskSizeGB           = $disk.DiskSizeGB
                DiskIOPSReadWrite    = $disk.DiskIOPSReadWrite
                DiskMBpsReadWrite    = $disk.DiskMBpsReadWrite
                Tier                 = $disk.Tier
                LogicalSectorSize    = if ($disk.CreationData) { $disk.CreationData.LogicalSectorSize } else { $null }
                DiskEncryptionSetId  = $disk.Encryption?.DiskEncryptionSetId
                Zones                = $disk.Zones
                Tags                 = $disk.Tags
            }
        }
    }
    
    return @{
        OsDisk    = $osDiskInfo
        DataDisks = $dataDisksInfo
    }
}

function Get-VMNicConfig {
    <#
    .SYNOPSIS
        Gets NIC configuration from the source VM.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine]$VM
    )
    
    $nicRef = $VM.NetworkProfile.NetworkInterfaces[0]
    $nicId = $nicRef.Id
    $nicName = $nicId.Split('/')[-1]
    $nicRg = $nicId.Split('/')[4]
    $nic = Get-AzNetworkInterface -Name $nicName -ResourceGroupName $nicRg
    
    $ipConfigs = @()
    foreach ($ipConfig in $nic.IpConfigurations) {
        $ipConfigs += @{
            Name                         = $ipConfig.Name
            Primary                      = $ipConfig.Primary
            PrivateIpAddress             = $ipConfig.PrivateIpAddress
            PrivateIpAllocationMethod    = $ipConfig.PrivateIpAllocationMethod.ToString()
            PrivateIpAddressVersion      = if ($ipConfig.PrivateIpAddressVersion) { $ipConfig.PrivateIpAddressVersion.ToString() } else { "IPv4" }
            SubnetId                     = if ($ipConfig.Subnet) { $ipConfig.Subnet.Id } else { $null }
            PublicIpAddressId            = $ipConfig.PublicIpAddress?.Id
            LoadBalancerBackendAddressPools = @($ipConfig.LoadBalancerBackendAddressPools | Where-Object { $_ } | ForEach-Object { $_.Id })
            LoadBalancerInboundNatRules  = @($ipConfig.LoadBalancerInboundNatRules | Where-Object { $_ } | ForEach-Object { $_.Id })
            ApplicationGatewayBackendAddressPools = @($ipConfig.ApplicationGatewayBackendAddressPools | Where-Object { $_ } | ForEach-Object { $_.Id })
            ApplicationSecurityGroups    = @($ipConfig.ApplicationSecurityGroups | Where-Object { $_ } | ForEach-Object { $_.Id })
        }
    }
    
    return @{
        Id                           = $nic.Id
        Name                         = $nic.Name
        ResourceGroupName            = $nicRg
        Location                     = $nic.Location
        IpConfigurations             = $ipConfigs
        DnsSettings                  = @{
            DnsServers               = @($nic.DnsSettings.DnsServers)
            InternalDnsNameLabel     = $nic.DnsSettings.InternalDnsNameLabel
        }
        EnableAcceleratedNetworking  = $nic.EnableAcceleratedNetworking
        EnableIPForwarding           = $nic.EnableIPForwarding
        NetworkSecurityGroupId       = $nic.NetworkSecurityGroup?.Id
        Tags                         = $nic.Tag
    }
}

function Get-VMExtensionsList {
    <#
    .SYNOPSIS
        Gets a list of extensions installed on the source VM.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine]$VM
    )
    
    $extensions = @()
    if (-not $VM.Extensions) {
        return $extensions
    }
    foreach ($ext in $VM.Extensions) {
        $extDetail = Get-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Name $ext.Name -ErrorAction SilentlyContinue
        if ($extDetail) {
            $extensions += @{
                Name              = $ext.Name
                Publisher         = $extDetail.Publisher
                ExtensionType     = $extDetail.ExtensionType
                TypeHandlerVersion = $extDetail.TypeHandlerVersion
            }
        }
    }
    return $extensions
}

function Test-VMRestorePointCompatibility {
    <#
    .SYNOPSIS
        Checks if a VM is compatible with VM restore points and warns about limitations.
    .DESCRIPTION
        VM restore points have specific limitations. This function checks if the source VM
        has any disks or configurations that are not supported and warns the user.
    .OUTPUTS
        Hashtable with: IsCompatible, Warnings, Errors
    #>
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine]$VM,
        [Parameter(Mandatory = $true)]
        [hashtable]$DiskInfo,
        [Parameter(Mandatory = $false)]
        [string]$ConsistencyMode = 'CrashConsistent'  # or 'ApplicationConsistent'
    )
    
    $result = @{
        IsCompatible = $true
        Warnings     = @()
        Errors       = @()
    }
    
    # Check all disks for compatibility issues
    $allDisks = @($DiskInfo.OsDisk) + @($DiskInfo.DataDisks)
    
    foreach ($disk in $allDisks) {
        $diskName = $disk.Name
        $diskSku = $disk.Sku
        
        # Get the actual disk to check additional properties
        $actualDisk = Get-AzDisk -ResourceGroupName $VM.ResourceGroupName -DiskName $diskName -ErrorAction SilentlyContinue
        
        if ($actualDisk) {
            # Check for Ultra disks - NOT supported for crash consistency
            if ($diskSku -eq 'UltraSSD_LRS') {
                if ($ConsistencyMode -eq 'CrashConsistent') {
                    $result.Errors += "Disk '$diskName' is an Ultra SSD. Ultra disks are NOT supported for crash-consistent restore points."
                    $result.IsCompatible = $false
                }
                else {
                    $result.Warnings += "Disk '$diskName' is an Ultra SSD. Ultra disks are NOT supported for crash-consistent mode but may work with application-consistent mode."
                }
            }
            
            # Check for Premium SSD v2 - NOT supported for crash consistency
            if ($diskSku -eq 'PremiumV2_LRS') {
                if ($ConsistencyMode -eq 'CrashConsistent') {
                    $result.Errors += "Disk '$diskName' is a Premium SSD v2. Premium SSD v2 disks are NOT supported for crash-consistent restore points."
                    $result.IsCompatible = $false
                }
                else {
                    $result.Warnings += "Disk '$diskName' is a Premium SSD v2. Premium SSD v2 disks are NOT supported for crash-consistent mode but may work with application-consistent mode."
                }
            }
            
            # Check for Write Accelerator - NOT supported for crash consistency
            # Note: Write Accelerator is set on the VM config, not the disk itself
            
            # Check for shared disks - NOT supported
            if ($actualDisk.MaxShares -and $actualDisk.MaxShares -gt 1) {
                $result.Errors += "Disk '$diskName' is a shared disk (MaxShares=$($actualDisk.MaxShares)). Shared disks are NOT supported for restore points."
                $result.IsCompatible = $false
            }
            
            # Check for Ephemeral OS disk - NOT supported
            if ($actualDisk.DiskState -eq 'Reserved' -and $disk.Name -eq $DiskInfo.OsDisk.Name) {
                # Check if it's an ephemeral disk by looking at the VM config
                if ($VM.StorageProfile.OsDisk.DiffDiskSettings) {
                    $result.Errors += "The OS disk is an Ephemeral disk. Ephemeral OS disks are NOT supported for restore points."
                    $result.IsCompatible = $false
                }
            }
        }
    }
    
    # Check for Write Accelerator on VM disks
    if ($VM.StorageProfile.OsDisk.WriteAcceleratorEnabled -eq $true) {
        if ($ConsistencyMode -eq 'CrashConsistent') {
            $result.Errors += "OS disk has Write Accelerator enabled. Write-accelerated disks are NOT supported for crash-consistent restore points."
            $result.IsCompatible = $false
        }
    }
    
    foreach ($dataDisk in $VM.StorageProfile.DataDisks) {
        if ($dataDisk.WriteAcceleratorEnabled -eq $true) {
            if ($ConsistencyMode -eq 'CrashConsistent') {
                $result.Errors += "Data disk '$($dataDisk.Name)' has Write Accelerator enabled. Write-accelerated disks are NOT supported for crash-consistent restore points."
                $result.IsCompatible = $false
            }
        }
    }
    
    # Check for Ephemeral OS disk via DiffDiskSettings
    if ($VM.StorageProfile.OsDisk.DiffDiskSettings) {
        $result.Errors += "The VM uses an Ephemeral OS disk. Ephemeral OS disks are NOT supported for restore points."
        $result.IsCompatible = $false
    }
    
    # Check for VMSS with Uniform orchestration (not applicable for standalone VMs, but document it)
    if ($VM.VirtualMachineScaleSet) {
        $result.Warnings += "This VM is part of a Virtual Machine Scale Set. Restore points for VMs in VMSS with Uniform orchestration are not supported."
    }
    
    return $result
}

function New-VMRestorePointCollection {
    <#
    .SYNOPSIS
        Creates a VM restore point collection for a source VM.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourceVMId,
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$CollectionName,
        [Parameter(Mandatory = $true)]
        [string]$Location
    )
    
    Write-Info "Creating restore point collection '$CollectionName'..."
    
    # Check if collection already exists
    $existingCollection = Get-AzRestorePointCollection -ResourceGroupName $ResourceGroupName -Name $CollectionName -ErrorAction SilentlyContinue
    if ($existingCollection) {
        Write-Warning "Restore point collection '$CollectionName' already exists. Using existing collection."
        return $existingCollection
    }
    
    $collection = New-AzRestorePointCollection `
        -ResourceGroupName $ResourceGroupName `
        -Name $CollectionName `
        -Location $Location `
        -VmId $SourceVMId
    
    Write-Success "Restore point collection '$CollectionName' created successfully."
    return $collection
}

function New-VMRestorePoint {
    <#
    .SYNOPSIS
        Creates a VM restore point within a restore point collection.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$CollectionName,
        [Parameter(Mandatory = $true)]
        [string]$RestorePointName,
        [Parameter(Mandatory = $false)]
        [string]$ConsistencyMode = 'CrashConsistent',  # or 'ApplicationConsistent'
        [Parameter(Mandatory = $false)]
        [int]$TimeoutMinutes = 30
    )
    
    Write-Info "Creating restore point '$RestorePointName' (mode: $ConsistencyMode)..."
    
    # Create the restore point
    $null = New-AzRestorePoint `
        -ResourceGroupName $ResourceGroupName `
        -RestorePointCollectionName $CollectionName `
        -Name $RestorePointName `
        -ConsistencyMode $ConsistencyMode
    
    # Wait for restore point to be ready
    $startTime = Get-Date
    $timeout = New-TimeSpan -Minutes $TimeoutMinutes
    $retryDelay = 5
    $maxRetryDelay = 30
    
    while ($true) {
        $currentRP = Get-AzRestorePoint `
            -ResourceGroupName $ResourceGroupName `
            -RestorePointCollectionName $CollectionName `
            -Name $RestorePointName
        
        if ($currentRP.ProvisioningState -eq 'Failed') {
            throw "Restore point '$RestorePointName' failed. State: $($currentRP.ProvisioningState)"
        }
        
        if ((Get-Date) - $startTime -gt $timeout) {
            throw "Timeout waiting for restore point '$RestorePointName' to complete. Current state: $($currentRP.ProvisioningState)"
        }
        
        if ($currentRP.ProvisioningState -eq 'Succeeded') {
            Write-Success "Restore point '$RestorePointName' created successfully."
            break
        }
        
        Write-Detail "Waiting for restore point... (State: $($currentRP.ProvisioningState))"
        Start-Sleep -Seconds $retryDelay
        $retryDelay = [Math]::Min($retryDelay * 1.5, $maxRetryDelay)
    }
    
    return $currentRP
}

function Get-DiskRestorePointIds {
    <#
    .SYNOPSIS
        Gets the disk restore point IDs from a VM restore point.
    .DESCRIPTION
        Returns a hashtable mapping disk names to their disk restore point IDs.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$CollectionName,
        [Parameter(Mandatory = $true)]
        [string]$RestorePointName,
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine]$SourceVM
    )
    
    Write-Info "Retrieving disk restore point IDs..."
    
    # Get the restore point with instance view to get disk restore points
    $restorePoint = Get-AzRestorePoint `
        -ResourceGroupName $ResourceGroupName `
        -RestorePointCollectionName $CollectionName `
        -Name $RestorePointName `
        -InstanceView
    
    if ($null -eq $restorePoint) {
        throw "Failed to retrieve restore point '$RestorePointName' from collection '$CollectionName'"
    }
    
    $diskRestorePoints = @{}
    
    # The restore point contains SourceMetadata.StorageProfile with disk info
    # And the disk restore points in the SourceRestorePoint.DiskRestorePoints collection
    
    if ($null -eq $restorePoint.SourceMetadata) {
        Write-Warning "Restore point SourceMetadata is null. Restore point may not have completed successfully."
        Write-Warning "Restore point provisioning state: $($restorePoint.ProvisioningState)"
        return $diskRestorePoints
    }
    
    if ($null -eq $restorePoint.SourceMetadata.StorageProfile) {
        Write-Warning "Restore point StorageProfile is null. Restore point may not have captured disk information."
        return $diskRestorePoints
    }
    
    $storageProfile = $restorePoint.SourceMetadata.StorageProfile
    
    # Map OS disk
    if ($storageProfile.OsDisk -and $storageProfile.OsDisk.DiskRestorePoint) {
        $osDiskName = $SourceVM.StorageProfile.OsDisk.Name
        if ([string]::IsNullOrEmpty($osDiskName)) {
            Write-Warning "Source VM OS disk name is null or empty"
        } else {
            $diskRestorePoints[$osDiskName] = $storageProfile.OsDisk.DiskRestorePoint.Id
            Write-Detail "  OS Disk: $osDiskName"
        }
    } else {
        Write-Warning "OS disk restore point not found in restore point metadata"
    }
    
    # Map data disks
    if ($storageProfile.DataDisks -and $storageProfile.DataDisks.Count -gt 0) {
        foreach ($dataDisk in $storageProfile.DataDisks) {
            if ($dataDisk.DiskRestorePoint) {
                # Find matching source disk by LUN
                $sourceDisk = $SourceVM.StorageProfile.DataDisks | Where-Object { $_.Lun -eq $dataDisk.Lun }
                if ($sourceDisk) {
                    $diskRestorePoints[$sourceDisk.Name] = $dataDisk.DiskRestorePoint.Id
                    Write-Detail "  Data Disk (LUN $($dataDisk.Lun)): $($sourceDisk.Name)"
                } else {
                    Write-Warning "Could not find source disk matching LUN $($dataDisk.Lun)"
                }
            }
        }
    }
    
    Write-Success "Retrieved $($diskRestorePoints.Count) disk restore point ID(s)."
    return $diskRestorePoints
}

function New-ZonalDiskFromRestorePoint {
    <#
    .SYNOPSIS
        Creates a new zonal managed disk from a disk restore point in the target resource group.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$DiskRestorePointId,
        [Parameter(Mandatory = $true)]
        [string]$NewDiskName,
        [Parameter(Mandatory = $true)]
        [string]$TargetResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$Location,
        [Parameter(Mandatory = $true)]
        [int]$Zone,
        [Parameter(Mandatory = $true)]
        [string]$SkuName,
        [Parameter(Mandatory = $false)]
        [int]$DiskSizeGB,
        [Parameter(Mandatory = $false)]
        [int]$DiskIOPSReadWrite,
        [Parameter(Mandatory = $false)]
        [int]$DiskMBpsReadWrite,
        [Parameter(Mandatory = $false)]
        [string]$Tier,
        [Parameter(Mandatory = $false)]
        [int]$LogicalSectorSize,
        [Parameter(Mandatory = $false)]
        [hashtable]$Tags,
        [Parameter(Mandatory = $false)]
        [string]$DiskEncryptionSetId,
        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 3
    )
    
    # Build disk config with encryption if specified
    if ($DiskEncryptionSetId) {
        $diskConfig = New-AzDiskConfig `
            -Location $Location `
            -Zone $Zone `
            -SkuName $SkuName `
            -CreateOption Restore `
            -SourceResourceId $DiskRestorePointId `
            -DiskEncryptionSetId $DiskEncryptionSetId
    }
    else {
        $diskConfig = New-AzDiskConfig `
            -Location $Location `
            -Zone $Zone `
            -SkuName $SkuName `
            -CreateOption Restore `
            -SourceResourceId $DiskRestorePointId
    }
    
    if ($DiskSizeGB -and $DiskSizeGB -gt 0) {
        $diskConfig.DiskSizeGB = $DiskSizeGB
    }
    
    if ($DiskIOPSReadWrite -and $DiskIOPSReadWrite -gt 0) {
        $diskConfig.DiskIOPSReadWrite = $DiskIOPSReadWrite
    }
    
    if ($DiskMBpsReadWrite -and $DiskMBpsReadWrite -gt 0) {
        $diskConfig.DiskMBpsReadWrite = $DiskMBpsReadWrite
    }
    
    if ($Tier) {
        $diskConfig.Tier = $Tier
    }
    
    if ($LogicalSectorSize -and $LogicalSectorSize -gt 0) {
        if ($null -eq $diskConfig.CreationData) {
            Write-Warning "Cannot set LogicalSectorSize - CreationData is null"
        } else {
            $diskConfig.CreationData.LogicalSectorSize = $LogicalSectorSize
        }
    }
    
    if ($Tags -and $Tags.Count -gt 0) {
        if ($null -eq $diskConfig.Tags) {
            $diskConfig.Tags = @{}
        }
        foreach ($key in $Tags.Keys) {
            $diskConfig.Tags[$key] = $Tags[$key]
        }
    }
    
    # Check if disk already exists
    $existingDisk = Get-AzDisk -ResourceGroupName $TargetResourceGroupName -DiskName $NewDiskName -ErrorAction SilentlyContinue
    if ($existingDisk) {
        Write-Warning "Disk '$NewDiskName' already exists in resource group '$TargetResourceGroupName'. Using existing disk."
        return $existingDisk
    }
    
    $retryCount = 0
    $lastError = $null
    
    while ($retryCount -lt $MaxRetries) {
        try {
            Write-Info "Creating zonal disk '$NewDiskName' in zone $Zone from restore point (attempt $($retryCount + 1)/$MaxRetries)..."
            $newDisk = New-AzDisk -ResourceGroupName $TargetResourceGroupName -DiskName $NewDiskName -Disk $diskConfig
            Write-Success "Zonal disk '$NewDiskName' created successfully."
            return $newDisk
        }
        catch {
            $lastError = $_
            $retryCount++
            
            if ($retryCount -lt $MaxRetries) {
                Write-Warning "Failed to create disk (attempt $retryCount/$MaxRetries): $($_.Exception.Message)"
                Write-Info "Waiting 30 seconds before retry..."
                Start-Sleep -Seconds 30
            }
        }
    }
    
    throw "Failed to create disk '$NewDiskName' after $MaxRetries attempts. Last error: $($lastError.Exception.Message)"
}

function Test-DiskSkuAvailability {
    <#
    .SYNOPSIS
        Checks if a disk SKU (especially PremiumV2_LRS or UltraSSD_LRS) is available 
        in the specified location and zone.
    .DESCRIPTION
        Uses Get-AzComputeResourceSku to determine regional and zonal availability
        for disk SKUs. This is especially important for Premium SSD v2 and Ultra SSD
        which have limited regional/zonal availability.
    .OUTPUTS
        Hashtable with: IsAvailable, AvailableZones, Message
    #>
    param(
        [Parameter(Mandatory)]
        [string]$SkuName,
        
        [Parameter(Mandatory)]
        [string]$Location,
        
        [Parameter(Mandatory)]
        [int]$Zone
    )
    
    $result = @{
        IsAvailable = $true
        AvailableZones = @()
        Message = ""
    }
    
    # Only check for SKUs that have limited availability
    if ($SkuName -notin @('PremiumV2_LRS', 'UltraSSD_LRS')) {
        return $result
    }
    
    # Query disk SKU availability
    $skuInfo = Get-AzComputeResourceSku -Location $Location | 
        Where-Object { $_.ResourceType -eq 'disks' -and $_.Name -eq $SkuName }
    
    if (-not $skuInfo) {
        $result.IsAvailable = $false
        $result.Message = "$SkuName is not available in location '$Location'"
        return $result
    }
    
    # Get location info for zones
    $locationInfo = $skuInfo.LocationInfo | Where-Object { $_.Location -eq $Location }
    
    if ($locationInfo -and $locationInfo.Zones) {
        $result.AvailableZones = @($locationInfo.Zones)
    }
    
    # Check zone-specific restrictions
    $zoneRestrictions = $skuInfo.Restrictions | Where-Object {
        $_.Type -eq 'Zone' -and 
        $_.RestrictionInfo.Zones -contains $Zone.ToString()
    }
    
    if ($zoneRestrictions) {
        $result.IsAvailable = $false
        $result.Message = "$SkuName is restricted in zone $Zone at location '$Location'. Reason: $($zoneRestrictions.ReasonCode)"
        return $result
    }
    
    # Check if the specific zone is in the available zones list
    if ($result.AvailableZones.Count -gt 0 -and $Zone.ToString() -notin $result.AvailableZones) {
        $result.IsAvailable = $false
        $availableZonesStr = $result.AvailableZones -join ', '
        $result.Message = "$SkuName is available in location '$Location' but not in zone $Zone. Available zones: $availableZonesStr"
        return $result
    }
    
    return $result
}

function Get-ZonalDiskParams {
    <#
    .SYNOPSIS
        Builds parameter hashtable for New-ZonalDiskFromRestorePoint, adding optional params only if present.
        Tags are taken from DiskInfo.Tags (the disk's own tags).
    #>
    param(
        [Parameter(Mandatory)] [string]$DiskRestorePointId,
        [Parameter(Mandatory)] [string]$NewDiskName,
        [Parameter(Mandatory)] [string]$TargetResourceGroupName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [int]$Zone,
        [Parameter(Mandatory)] [string]$SkuName,
        [string]$SourceSkuName,
        [hashtable]$DiskInfo,
        [int]$MaxRetries = 3
    )
    
    $params = @{
        DiskRestorePointId      = $DiskRestorePointId
        NewDiskName             = $NewDiskName
        TargetResourceGroupName = $TargetResourceGroupName
        Location                = $Location
        Zone                    = $Zone
        SkuName                 = $SkuName
        MaxRetries              = $MaxRetries
    }
    
    # Check if we're converting to PremiumV2 or Ultra from a different SKU
    $isConvertingToAdvancedSku = ($SkuName -in @('PremiumV2_LRS', 'UltraSSD_LRS')) -and ($SourceSkuName -notin @('PremiumV2_LRS', 'UltraSSD_LRS'))
    
    # Add optional disk properties if present
    # Skip IOPS/throughput when converting TO PremiumV2/Ultra (they have different minimums/defaults)
    $propsToSkipOnConversion = @('DiskIOPSReadWrite', 'DiskMBpsReadWrite', 'Tier')
    
    @('DiskSizeGB', 'DiskIOPSReadWrite', 'DiskMBpsReadWrite', 'Tier', 'LogicalSectorSize', 'DiskEncryptionSetId') | ForEach-Object {
        if ($DiskInfo.$_) {
            # Skip IOPS/throughput/tier when converting to advanced SKUs - let Azure use defaults
            if ($isConvertingToAdvancedSku -and $_ -in $propsToSkipOnConversion) {
                return  # Skip this property
            }
            $params.$_ = $DiskInfo.$_
        }
    }
    
    # Copy the disk's own tags (if any) - no fallback to VM tags
    if ($DiskInfo.Tags -and $DiskInfo.Tags.Count -gt 0) {
        $params.Tags = $DiskInfo.Tags
    }
    
    return $params
}

function Copy-NetworkInterfaceConfig {
    <#
    .SYNOPSIS
        Creates a new NIC in the target resource group with all configurations copied from source.
        The new NIC will be assigned a dynamic IP by Azure.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [object]$SourceNicConfig,
        [Parameter(Mandatory = $true)]
        [string]$NewNicName,
        [Parameter(Mandatory = $true)]
        [string]$TargetResourceGroupName
    )
    
    # Build IP configurations - use dynamic allocation (Azure assigns IP)
    $ipConfigurations = @()
    
    foreach ($sourceIpConfig in $SourceNicConfig.IpConfigurations) {
        $ipConfigParams = @{
            Name                         = $sourceIpConfig.Name
            SubnetId                     = $sourceIpConfig.SubnetId
            Primary                      = $sourceIpConfig.Primary
            PrivateIpAddressVersion      = $sourceIpConfig.PrivateIpAddressVersion ?? "IPv4"
        }
        
        # Dynamic allocation - Azure will assign an available IP
        # Note: We don't copy PublicIpAddress as it can only be attached to one NIC
        
        # Add load balancer backend pools
        if ($sourceIpConfig.LoadBalancerBackendAddressPools -and $sourceIpConfig.LoadBalancerBackendAddressPools.Count -gt 0) {
            $ipConfigParams.LoadBalancerBackendAddressPoolId = $sourceIpConfig.LoadBalancerBackendAddressPools
        }
        
        # Add load balancer inbound NAT rules
        if ($sourceIpConfig.LoadBalancerInboundNatRules -and $sourceIpConfig.LoadBalancerInboundNatRules.Count -gt 0) {
            $ipConfigParams.LoadBalancerInboundNatRuleId = $sourceIpConfig.LoadBalancerInboundNatRules
        }
        
        # Add application gateway backend pools
        if ($sourceIpConfig.ApplicationGatewayBackendAddressPools -and $sourceIpConfig.ApplicationGatewayBackendAddressPools.Count -gt 0) {
            $ipConfigParams.ApplicationGatewayBackendAddressPoolId = $sourceIpConfig.ApplicationGatewayBackendAddressPools
        }
        
        # Add application security groups
        if ($sourceIpConfig.ApplicationSecurityGroups -and $sourceIpConfig.ApplicationSecurityGroups.Count -gt 0) {
            $ipConfigParams.ApplicationSecurityGroupId = $sourceIpConfig.ApplicationSecurityGroups
        }
        
        $newIpConfig = New-AzNetworkInterfaceIpConfig @ipConfigParams
        $ipConfigurations += $newIpConfig
    }
    
    # Build NIC parameters
    $nicParams = @{
        Name                        = $NewNicName
        ResourceGroupName           = $TargetResourceGroupName
        Location                    = $SourceNicConfig.Location
        IpConfiguration             = $ipConfigurations
        EnableAcceleratedNetworking = $SourceNicConfig.EnableAcceleratedNetworking
        EnableIPForwarding          = $SourceNicConfig.EnableIPForwarding
    }
    
    # Add DNS settings
    if ($SourceNicConfig.DnsSettings.DnsServers -and $SourceNicConfig.DnsSettings.DnsServers.Count -gt 0) {
        $nicParams.DnsServer = $SourceNicConfig.DnsSettings.DnsServers
    }
    
    if ($SourceNicConfig.DnsSettings.InternalDnsNameLabel) {
        $nicParams.InternalDnsNameLabel = $SourceNicConfig.DnsSettings.InternalDnsNameLabel
    }
    
    # Add NSG
    if ($SourceNicConfig.NetworkSecurityGroupId) {
        $nicParams.NetworkSecurityGroupId = $SourceNicConfig.NetworkSecurityGroupId
    }
    
    # Add tags (only if they exist and have values)
    if ($SourceNicConfig.Tags -and $SourceNicConfig.Tags.Count -gt 0) {
        $nicParams.Tag = $SourceNicConfig.Tags
    }
    
    Write-Info "Creating new NIC '$NewNicName' in resource group '$TargetResourceGroupName'..."
    $newNic = New-AzNetworkInterface @nicParams
    
    Write-Success "NIC '$NewNicName' created successfully."
    return $newNic
}

#endregion

#region Main Script

Write-Host "`n"
Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║           AZURE VM ZONAL COPY SCRIPT                                         ║" -ForegroundColor Cyan
Write-Host "║           Creates a copy of a VM in a target availability zone               ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan

# Verify Azure context is set
$currentContext = Get-AzContext
if (-not $currentContext -or -not $currentContext.Subscription) {
    throw "No Azure context set. Please run 'Set-AzContext -SubscriptionId <your-subscription-id>' before running this script."
}
Write-Info "Using subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))"

#region Step 1: Retrieve and Validate Source VM
Write-StepHeader "1" "Retrieve and Validate Source VM"

# --- GATHER ALL INFORMATION FIRST ---
Write-Info "Looking for the source VM..."
$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
if (-not $vm) {
    throw "VM '$VMName' not found in resource group '$ResourceGroupName'."
}
$vmConfig = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName

# Check for multiple NICs early
if ($vmConfig.NetworkProfile.NetworkInterfaces.Count -gt 1) {
    throw "VM '$VMName' has $($vmConfig.NetworkProfile.NetworkInterfaces.Count) NICs. This script only supports VMs with a single NIC."
}

Write-Info "Gathering NIC configuration..."
$nicConfig = Get-VMNicConfig -VM $vmConfig
$primaryIpConfig = $nicConfig.IpConfigurations | Where-Object { $_.Primary -eq $true }
$sourceIpAddress = $primaryIpConfig.PrivateIpAddress
$sourceIpAllocation = $primaryIpConfig.PrivateIpAllocationMethod

# Check for public IPs
$hasPublicIp = $false
$publicIpNames = @()
foreach ($ipConfig in $nicConfig.IpConfigurations) {
    if ($ipConfig.PublicIpAddressId) {
        $hasPublicIp = $true
        $publicIpNames += $ipConfig.PublicIpAddressId.Split('/')[-1]
    }
}

Write-Info "Gathering disk information..."
$diskInfo = Get-VMDiskInfo -VM $vmConfig

Write-Info "Checking Azure Disk Encryption status..."
$adeStatus = Get-AzVmDiskEncryptionStatus -ResourceGroupName $ResourceGroupName -VMName $VMName -ErrorAction SilentlyContinue

Write-Info "Checking restore point compatibility..."
$rpCompatibility = Test-VMRestorePointCompatibility -VM $vmConfig -DiskInfo $diskInfo -ConsistencyMode 'CrashConsistent'

Write-Info "Gathering extension list..."
$sourceExtensions = @(Get-VMExtensionsList -VM $vmConfig)

# --- DISPLAY ALL GATHERED INFORMATION ---
Write-Host ""
Write-Host "  VM DETAILS" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────────────────────────────────────────" -ForegroundColor Gray
Write-Host "  Name       : $VMName" -ForegroundColor Gray
Write-Host "  Location   : $($vmConfig.Location)" -ForegroundColor Gray
Write-Host "  VM Size    : $($vmConfig.HardwareProfile.VmSize)" -ForegroundColor Gray
Write-Host "  Zone       : $(($vmConfig.Zones -and $vmConfig.Zones.Count -gt 0) ? $vmConfig.Zones[0] : 'None (Regional)')" -ForegroundColor Gray
Write-Host ""

Write-Host "  NETWORK CONFIGURATION" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────────────────────────────────────────" -ForegroundColor Gray
Write-Host "  NIC        : $($nicConfig.Name)" -ForegroundColor Gray
Write-Host "  IP Address : $sourceIpAddress ($sourceIpAllocation)" -ForegroundColor Gray
if ($hasPublicIp) {
    Write-Host "  Public IP  : $($publicIpNames -join ', ') (will NOT be copied)" -ForegroundColor Yellow
} else {
    Write-Host "  Public IP  : None" -ForegroundColor Gray
}
Write-Host ""

Write-Host "  DISK INVENTORY" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────────────────────────────────────────" -ForegroundColor Gray

# OS Disk
$osEncType = $diskInfo.OsDisk.DiskEncryptionSetId ? "SSE+CMK" : "SSE+PMK"
$osZoneInfo = ($diskInfo.OsDisk.Zones -and $diskInfo.OsDisk.Zones.Count -gt 0) ? "Zone $($diskInfo.OsDisk.Zones[0])" : "Regional"
Write-Host "  OS Disk:" -ForegroundColor Cyan
Write-Host "    $($diskInfo.OsDisk.Name)" -ForegroundColor White
Write-Host "      SKU: $($diskInfo.OsDisk.Sku) | Size: $($diskInfo.OsDisk.DiskSizeGB) GB | $osZoneInfo | Encryption: $osEncType" -ForegroundColor Gray

# Data Disks
if ($diskInfo.DataDisks.Count -gt 0) {
    Write-Host "  Data Disks ($($diskInfo.DataDisks.Count)):" -ForegroundColor Cyan
    foreach ($dd in $diskInfo.DataDisks | Sort-Object { $_.Lun }) {
        $ddEncType = $dd.DiskEncryptionSetId ? "SSE+CMK" : "SSE+PMK"
        $ddZoneInfo = ($dd.Zones -and $dd.Zones.Count -gt 0) ? "Zone $($dd.Zones[0])" : "Regional"
        Write-Host "    LUN $($dd.Lun): $($dd.Name) | $($dd.Sku) | $($dd.DiskSizeGB) GB | $ddZoneInfo | $ddEncType" -ForegroundColor Gray
    }
}
Write-Host ""

if ($sourceExtensions.Count -gt 0) {
    Write-Host "  EXTENSIONS ($($sourceExtensions.Count))" -ForegroundColor Yellow
    Write-Host "  ──────────────────────────────────────────────────────────────────────────────" -ForegroundColor Gray
    foreach ($ext in $sourceExtensions) {
        Write-Host "    $($ext.Name) ($($ext.Publisher))" -ForegroundColor Gray
    }
    Write-Host ""
}

# --- RUN VALIDATION CHECKS ---
Write-Host "  VALIDATION CHECKS" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────────────────────────────────────────" -ForegroundColor Gray

# Public IP warning (NIC-related - first to match gathering order)
if ($hasPublicIp) {
    Write-Host "  [!] Public IPs will NOT be copied (manual action required)" -ForegroundColor Yellow
} else {
    Write-Host "  [✓] No public IPs to migrate" -ForegroundColor Green
}

# Check for Azure Disk Encryption (ADE)
if ($adeStatus) {
    $osEncrypted = $adeStatus.OsVolumeEncrypted -eq 'Encrypted'
    $dataEncrypted = $adeStatus.DataVolumesEncrypted -eq 'Encrypted'
    
    if ($osEncrypted -or $dataEncrypted) {
        Write-Host ""
        Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
        Write-Host "║                    AZURE DISK ENCRYPTION (ADE) DETECTED                      ║" -ForegroundColor Red
        Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
        Write-Host ""
        Write-Host "  OS Volume Encrypted:   $($adeStatus.OsVolumeEncrypted)" -ForegroundColor Yellow
        Write-Host "  Data Volumes Encrypted: $($adeStatus.DataVolumesEncrypted)" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  This VM uses Azure Disk Encryption (BitLocker/dm-crypt)." -ForegroundColor White
        Write-Host "  ADE-encrypted disks CANNOT be simply copied to a new VM." -ForegroundColor White
        Write-Host ""
        Write-Host "  What would happen:" -ForegroundColor Cyan
        Write-Host "    - Disks would be LOCKED and INACCESSIBLE on the new VM" -ForegroundColor White
        Write-Host "    - The new VM would fail to boot (OS disk) or access data (data disks)" -ForegroundColor White
        Write-Host "    - BitLocker/dm-crypt keys are stored in Azure Key Vault" -ForegroundColor White
        Write-Host "    - The AzureDiskEncryption extension is required to fetch keys" -ForegroundColor White
        Write-Host ""
        Write-Host "  Recommended actions:" -ForegroundColor Cyan
        Write-Host "    1. Disable ADE on the source VM first (Windows data disks, all Linux data disks)" -ForegroundColor White
        Write-Host "    2. For Linux OS disks: Create a new VM with a fresh OS disk" -ForegroundColor White
        Write-Host "    3. Consider migrating to 'Encryption at Host' instead of ADE" -ForegroundColor White
        Write-Host "       (See: https://learn.microsoft.com/azure/virtual-machines/disk-encryption-migrate)" -ForegroundColor Gray
        Write-Host ""
        throw "Cannot proceed: VM '$VMName' has Azure Disk Encryption enabled. Please disable ADE before running this script."
    }
}
Write-Host "  [✓] No Azure Disk Encryption (ADE)" -ForegroundColor Green

# Check VM restore point compatibility
if ($rpCompatibility.Warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Yellow
    Write-Host "║                    VM RESTORE POINT WARNINGS                                 ║" -ForegroundColor Yellow
    Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Yellow
    Write-Host ""
    foreach ($warning in $rpCompatibility.Warnings) {
        Write-Host "  [!] $warning" -ForegroundColor Yellow
    }
    Write-Host ""
}

if (-not $rpCompatibility.IsCompatible) {
    Write-Host ""
    Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
    Write-Host "║              VM RESTORE POINT COMPATIBILITY ERRORS                           ║" -ForegroundColor Red
    Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
    Write-Host ""
    foreach ($err in $rpCompatibility.Errors) {
        Write-Host "  [X] $err" -ForegroundColor Red
    }
    Write-Host ""
    Write-Host "  VM restore points cannot be used for this VM due to the above limitations." -ForegroundColor White
    Write-Host "  See: https://learn.microsoft.com/azure/virtual-machines/virtual-machines-create-restore-points#limitations" -ForegroundColor Gray
    Write-Host ""
    throw "Cannot proceed: VM '$VMName' is not compatible with VM restore points."
}
Write-Host "  [✓] VM is compatible with restore points" -ForegroundColor Green

# Validate disk caching for Ultra/PremiumV2 disks
$sourceOsSku = $diskInfo.OsDisk.Sku
if ($sourceOsSku -in @('PremiumV2_LRS', 'UltraSSD_LRS') -and -not $TargetOsDiskSku) {
    if ($diskInfo.OsDisk.Caching -ne 'None') {
        throw "OS Disk '$($diskInfo.OsDisk.Name)' is $sourceOsSku which only supports Caching='None'. Current caching is '$($diskInfo.OsDisk.Caching)'. Please change the caching setting on the source disk before running this script."
    }
}

foreach ($dataDisk in $diskInfo.DataDisks) {
    $sourceSku = $dataDisk.Sku
    if ($sourceSku -in @('PremiumV2_LRS', 'UltraSSD_LRS') -and -not $TargetDataDiskSku) {
        if ($dataDisk.Caching -ne 'None') {
            throw "Data Disk '$($dataDisk.Name)' is $sourceSku which only supports Caching='None'. Current caching is '$($dataDisk.Caching)'. Please change the caching setting on the source disk before running this script."
        }
    }
}
Write-Host "  [✓] Disk caching settings valid" -ForegroundColor Green

Write-Host ""
Write-Success "Source VM validated successfully."

#endregion

#region Step 2: Validate Target Configuration
Write-StepHeader "2" "Validate Target Configuration"

# Set default target resource group if not specified
if (-not $TargetResourceGroupName) {
    $TargetResourceGroupName = $ResourceGroupName
}

# Check if target and source resource groups are the same
$sameResourceGroup = ($TargetResourceGroupName -eq $ResourceGroupName)

# Validate target resource group exists
$targetRg = Get-AzResourceGroup -Name $TargetResourceGroupName -ErrorAction SilentlyContinue
if (-not $targetRg) {
    throw "Target resource group '$TargetResourceGroupName' does not exist. Please create it first."
}

# Handle VM naming based on whether we're in the same or different resource group
if ($sameResourceGroup) {
    # Same resource group - NewVMName is REQUIRED and must be different
    if (-not $NewVMName) {
        throw "When target resource group is the same as source, you must specify a different NewVMName. Source VM: '$VMName'"
    }
    if ($NewVMName -eq $VMName) {
        throw "NewVMName ('$NewVMName') must be different from source VMName ('$VMName') when using the same resource group."
    }
}
else {
    # Different resource group - NewVMName defaults to VMName if not specified
    if (-not $NewVMName) {
        $NewVMName = $VMName
    }
}

# Check if new VM already exists
$existingVM = Get-AzVM -ResourceGroupName $TargetResourceGroupName -Name $NewVMName -ErrorAction SilentlyContinue
if ($existingVM) {
    throw "A VM named '$NewVMName' already exists in resource group '$TargetResourceGroupName'."
}

# Retrieve physical zone mapping early for display
$physicalZone = Get-PhysicalZone -Location $vmConfig.Location -LogicalZone $TargetZone

# Display target configuration
Write-Host ""
Write-Host "  DESIRED TARGET CONFIGURATION" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────────────────────────────────────────" -ForegroundColor Gray
Write-Host "  Resource Group : $TargetResourceGroupName$(if ($sameResourceGroup) { ' (same as source)' } else { ' (different from source)' })" -ForegroundColor Gray
Write-Host "  New VM Name    : $NewVMName" -ForegroundColor Gray
$physicalZoneStr = $physicalZone ? " (physical zone: $physicalZone)" : ""
Write-Host "  Target Zone    : $TargetZone$physicalZoneStr" -ForegroundColor Gray
# SKU conversion info (inline)
if ($TargetOsDiskSku -and $TargetOsDiskSku -ne $diskInfo.OsDisk.Sku) {
    Write-Host "  OS Disk SKU    : $($diskInfo.OsDisk.Sku) -> $TargetOsDiskSku" -ForegroundColor Gray
}
if ($TargetDataDiskSku) {
    Write-Host "  Data Disk SKU  : All will use $TargetDataDiskSku" -ForegroundColor Gray
}
Write-Host ""

# Run validations
Write-Info "Validating target configuration..."
Write-Host ""
Write-Host "  VALIDATION CHECKS" -ForegroundColor Yellow
Write-Host "  ──────────────────────────────────────────────────────────────────────────────" -ForegroundColor Gray

# Validate VM size is available in target zone
$vmSize = $vmConfig.HardwareProfile.VmSize
$location = $vmConfig.Location

$skuAvailability = Get-AzComputeResourceSku -Location $location | 
    Where-Object { 
        $_.ResourceType -eq 'virtualMachines' -and 
        $_.Name -eq $vmSize 
    }

if (-not $skuAvailability) {
    throw "VM size '$vmSize' is not available in location '$location'."
}

$zoneInfo = $skuAvailability.LocationInfo | Where-Object { $_.Location -eq $location }
$availableZones = $zoneInfo.Zones

if (-not $availableZones -or $TargetZone -notin $availableZones) {
    $availableZonesStr = $availableZones ? ($availableZones -join ', ') : 'None'
    throw "VM size '$vmSize' is not available in zone $TargetZone at location '$location'. Available zones: $availableZonesStr"
}

# Check for restrictions
$restrictions = $skuAvailability.Restrictions | Where-Object { 
    $_.Type -eq 'Zone' -and 
    $_.RestrictionInfo.Zones -contains $TargetZone 
}

if ($restrictions) {
    $reasonCode = $restrictions.ReasonCode
    throw "VM size '$vmSize' is restricted in zone $TargetZone at location '$location'. Reason: $reasonCode"
}

Write-Host "  [✓] VM size '$vmSize' available in zone $TargetZone" -ForegroundColor Green

# Validate Premium SSD v2 / Ultra SSD availability in target zone (if applicable)
$effectiveOsDiskSku = $TargetOsDiskSku ? $TargetOsDiskSku : $diskInfo.OsDisk.Sku
$effectiveDataDiskSku = $TargetDataDiskSku

$skusToValidate = @()
if ($effectiveOsDiskSku -in @('PremiumV2_LRS', 'UltraSSD_LRS')) {
    $skusToValidate += $effectiveOsDiskSku
}
if ($effectiveDataDiskSku -in @('PremiumV2_LRS', 'UltraSSD_LRS')) {
    $skusToValidate += $effectiveDataDiskSku
}
if (-not $TargetOsDiskSku -and $diskInfo.OsDisk.Sku -in @('PremiumV2_LRS', 'UltraSSD_LRS')) {
    $skusToValidate += $diskInfo.OsDisk.Sku
}
if (-not $TargetDataDiskSku) {
    foreach ($dataDisk in $diskInfo.DataDisks) {
        if ($dataDisk.Sku -in @('PremiumV2_LRS', 'UltraSSD_LRS')) {
            $skusToValidate += $dataDisk.Sku
        }
    }
}

$skusToValidate = @($skusToValidate | Sort-Object -Unique)
foreach ($skuToValidate in $skusToValidate) {
    $skuCheck = Test-DiskSkuAvailability -SkuName $skuToValidate -Location $vmConfig.Location -Zone $TargetZone
    
    if (-not $skuCheck.IsAvailable) {
        throw $skuCheck.Message
    }
    Write-Host "  [✓] $skuToValidate available in zone $TargetZone" -ForegroundColor Green
}

Write-Host ""
Write-Success "Target configuration validated."

#endregion

#region Step 3: Check for Proximity Placement Group
Write-StepHeader "3" "Check for Proximity Placement Group"

# Script-level variable to store validated PPG for VM creation
$script:targetPPGObject = $null

function Test-PPGZoneCompatibility {
    <#
    .SYNOPSIS
        Tests if a Proximity Placement Group is compatible with a target availability zone.
    .DESCRIPTION
        Checks if the PPG can accept a new VM in the target zone by examining:
        - Existing zonal VMs (which pin the PPG to a specific zone)
        - Running regional VMs (which physically pin the PPG to hardware that may not be in the target zone)
    .OUTPUTS
        Hashtable with: IsCompatible, PinnedZone, VMsInPPG, RunningRegionalVMs, Message
    #>
    param (
        [Parameter(Mandatory)]
        $PPG,
        [Parameter(Mandatory)]
        [int]$TargetZone,
        [string]$SourceVMName,
        [string]$SourceRG
    )
    
    $result = @{
        IsCompatible = $true
        PinnedZone = $null
        VMsInPPG = @()
        RunningRegionalVMs = @()
        Message = ""
    }
    
    # Check if PPG already has VMs deployed (which pins it to a zone)
    $ppgVMs = @()
    if ($PPG.VirtualMachines) {
        $ppgVMs = @($PPG.VirtualMachines | ForEach-Object { $_.Id })
    }
    
    if ($ppgVMs.Count -gt 0) {
        $ppgZones = @()
        foreach ($vmId in $ppgVMs) {
            $vmNameInPpg = $vmId.Split('/')[-1]
            $vmRgInPpg = $vmId.Split('/')[4]
            
            # Skip the source VM if checking source PPG
            if ($vmNameInPpg -eq $SourceVMName -and $vmRgInPpg -eq $SourceRG) {
                $result.VMsInPPG += @{ Name = $vmNameInPpg; Zone = "Source"; IsSource = $true; IsRunning = $false }
                continue
            }
            
            # Get VM config and status
            $vmInPpg = Get-AzVM -ResourceGroupName $vmRgInPpg -Name $vmNameInPpg -ErrorAction SilentlyContinue
            $vmStatus = Get-AzVM -ResourceGroupName $vmRgInPpg -Name $vmNameInPpg -Status -ErrorAction SilentlyContinue
            
            if ($vmInPpg) {
                $vmZone = ($vmInPpg.Zones -and $vmInPpg.Zones.Count -gt 0) ? $vmInPpg.Zones[0] : "Regional"
                $powerState = $vmStatus ? ($vmStatus.Statuses | Where-Object { $_.Code -like 'PowerState/*' }).Code : "Unknown"
                $isRunning = $powerState -eq 'PowerState/running'
                
                $result.VMsInPPG += @{ 
                    Name = $vmNameInPpg
                    Zone = $vmZone
                    IsSource = $false
                    IsRunning = $isRunning
                    PowerState = $powerState
                }
                
                if ($vmZone -ne "Regional") {
                    $ppgZones += [int]$vmZone
                }
                elseif ($isRunning) {
                    # Track running regional VMs - they physically pin the PPG
                    $result.RunningRegionalVMs += $vmNameInPpg
                }
            }
        }
        
        # Check zone compatibility
        $uniqueZones = @($ppgZones | Sort-Object -Unique)
        if ($uniqueZones.Count -gt 0) {
            $result.PinnedZone = $uniqueZones[0]
            
            if ($result.PinnedZone -ne $TargetZone) {
                $result.IsCompatible = $false
                $result.Message = "PPG is pinned to Zone $($result.PinnedZone) but target zone is $TargetZone"
            }
        }
        
        # If no zonal VMs but there are running regional VMs, the PPG is physically pinned
        # to whatever hardware those VMs are on - which may conflict with the target zone
        if ($result.IsCompatible -and $uniqueZones.Count -eq 0 -and $result.RunningRegionalVMs.Count -gt 0) {
            $result.IsCompatible = $false
            $result.Message = "PPG has running regional VMs that physically pin it to unknown hardware"
        }
    }
    
    return $result
}

# Check if source VM is in a PPG
$sourcePPGId = $vmConfig.ProximityPlacementGroup?.Id

if ($sourcePPGId) {
    $sourcePpgName = $sourcePPGId.Split('/')[-1]
    $sourcePpgRg = $sourcePPGId.Split('/')[4]
    
    Write-Info "Source VM is in Proximity Placement Group: $sourcePpgName"
    
    $sourcePPG = Get-AzProximityPlacementGroup -ResourceGroupName $sourcePpgRg -Name $sourcePpgName -ErrorAction SilentlyContinue
    
    if ($sourcePPG) {
        $ppgCheck = Test-PPGZoneCompatibility -PPG $sourcePPG -TargetZone $TargetZone -SourceVMName $VMName -SourceRG $ResourceGroupName
        
        # Show VMs in PPG
        $vmsInPpg = @($ppgCheck.VMsInPPG)
        if ($vmsInPpg.Count -gt 0) {
            $nonSourceVMs = @($vmsInPpg | Where-Object { -not $_.IsSource })
            if ($nonSourceVMs.Count -gt 0) {
                Write-Info "PPG '$sourcePpgName' contains other VMs:"
                foreach ($ppgVm in $nonSourceVMs) {
                    $zoneText = $ppgVm.Zone -eq "Regional" ? "Regional" : "Zone $($ppgVm.Zone)"
                    if ($ppgVm.IsRunning) {
                        Write-Host "     - $($ppgVm.Name) ($zoneText, " -NoNewline -ForegroundColor Gray
                        Write-Host "Running" -NoNewline -ForegroundColor Green
                        Write-Host ")" -ForegroundColor Gray
                    }
                    else {
                        Write-Host "     - $($ppgVm.Name) ($zoneText, " -NoNewline -ForegroundColor Gray
                        Write-Host "Deallocated" -NoNewline -ForegroundColor DarkGray
                        Write-Host ")" -ForegroundColor Gray
                    }
                }
            }
            else {
                Write-Detail "PPG '$sourcePpgName' contains only the source VM."
            }
        }
        else {
            Write-Detail "PPG '$sourcePpgName' has no VMs deployed."
        }
        
        # Check zone compatibility and decide whether to use the PPG
        if ($ppgCheck.IsCompatible) {
            # PPG is compatible - use it
            if ($ppgCheck.PinnedZone) {
                Write-Success "PPG '$sourcePpgName' is pinned to Zone $($ppgCheck.PinnedZone) - compatible with target Zone $TargetZone."
            }
            else {
                # Check if there are any regional (non-zonal) VMs that are deallocated
                $regionalVMs = @($ppgCheck.VMsInPPG | Where-Object { $_.Zone -eq "Regional" -and -not $_.IsSource })
                if ($regionalVMs.Count -gt 0) {
                    Write-Success "PPG '$sourcePpgName' has regional VMs but all are deallocated - PPG is not pinned."
                    Write-Detail "  The PPG will be pinned to Zone $TargetZone when the new VM is created."
                }
                else {
                    Write-Success "PPG '$sourcePpgName' is not yet pinned to a zone - will be pinned to Zone $TargetZone."
                }
            }
            Write-Success "New VM will be assigned to PPG '$sourcePpgName'."
            $script:targetPPGObject = $sourcePPG
        }
        else {
            # PPG is NOT compatible - stop the script with specific error
            Write-Host ""
            
            if ($ppgCheck.RunningRegionalVMs.Count -gt 0) {
                # Running regional VMs physically pin the PPG
                Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
                Write-Host "║                    PPG PHYSICAL PINNING CONFLICT                             ║" -ForegroundColor Red
                Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
                Write-Host ""
                Write-Host "  Running regional VMs physically pin the PPG to specific hardware." -ForegroundColor White
                Write-Host "  This hardware may not be in the target Zone $TargetZone." -ForegroundColor White
                Write-Host ""
                Write-Host "  ACTION REQUIRED:" -ForegroundColor Cyan
                Write-Host "    Stop (deallocate) the running regional VMs listed above, then re-run this script." -ForegroundColor White
                Write-Host ""
                throw "Cannot proceed: PPG '$sourcePpgName' has running regional VMs that physically pin it. Stop these VMs first."
            }
            elseif ($ppgCheck.PinnedZone) {
                # Zonal VMs pin the PPG to a different zone
                Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
                Write-Host "║                         PPG ZONE MISMATCH                                    ║" -ForegroundColor Red
                Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
                Write-Host ""
                Write-Host "  PPG '$sourcePpgName' is pinned to Zone $($ppgCheck.PinnedZone)" -ForegroundColor Yellow
                Write-Host "  Target zone for new VM is Zone $TargetZone" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  PPGs require all VMs to be in the same availability zone." -ForegroundColor White
                Write-Host ""
                Write-Host "  ACTION REQUIRED:" -ForegroundColor Cyan
                Write-Host "    Change the -TargetZone parameter to $($ppgCheck.PinnedZone) to match the existing VMs in the PPG." -ForegroundColor White
                Write-Host ""
                throw "Cannot proceed: PPG '$sourcePpgName' is pinned to Zone $($ppgCheck.PinnedZone), but target zone is $TargetZone. Use -TargetZone $($ppgCheck.PinnedZone) instead."
            }
            else {
                # Generic incompatibility
                Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Red
                Write-Host "║                         PPG INCOMPATIBLE                                     ║" -ForegroundColor Red
                Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Red
                Write-Host ""
                Write-Host "  $($ppgCheck.Message)" -ForegroundColor Yellow
                Write-Host ""
                throw "Cannot proceed: PPG '$sourcePpgName' is incompatible with the target zone. $($ppgCheck.Message)"
            }
        }
    }
    else {
        Write-Warning "Could not retrieve PPG '$sourcePpgName'. New VM will not be assigned to a PPG."
    }
}
else {
    Write-Success "Source VM is not in a Proximity Placement Group."
}

#endregion

#region Step 4: Stop Source VM (for consistent snapshots)
Write-StepHeader "4" "Stop Source VM"

$vmStatus = ($vm.Statuses | Where-Object { $_.Code -like 'PowerState/*' }).Code
Write-Detail "Current power state: $vmStatus"

if ($vmStatus -ne 'PowerState/deallocated') {
    if ($PSCmdlet.ShouldProcess($VMName, "Stop VM for consistent snapshots")) {
        Write-Info "Stopping VM '$VMName' for consistent snapshots..."
        Stop-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Force | Out-Null
        Write-Success "VM '$VMName' stopped and deallocated."
    }
    else {
        Write-Info "[WhatIf] Would stop VM '$VMName'."
    }
}
else {
    Write-Success "VM '$VMName' is already deallocated."
}

#endregion

#region Step 5: Create VM Restore Point
Write-StepHeader "5" "Create VM Restore Point"

# Generate unique names for restore point collection and restore point
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$rpCollectionName = "$VMName-rpc-$timestamp"
$rpName = "$VMName-rp-$timestamp"

# Truncate names if needed (Azure has 80 char limit)
if ($rpCollectionName.Length -gt 80) {
    $rpCollectionName = $rpCollectionName.Substring(0, 80)
}
if ($rpName.Length -gt 80) {
    $rpName = $rpName.Substring(0, 80)
}

$restorePointData = @{
    CollectionName = $rpCollectionName
    RestorePointName = $rpName
    DiskRestorePoints = @{}
}

if ($PSCmdlet.ShouldProcess($VMName, "Create VM restore point")) {
    # Create restore point collection in source resource group (must be same RG as VM)
    $null = New-VMRestorePointCollection `
        -SourceVMId $vmConfig.Id `
        -ResourceGroupName $ResourceGroupName `
        -CollectionName $rpCollectionName `
        -Location $vmConfig.Location
    
    # Create restore point (crash-consistent)
    $null = New-VMRestorePoint `
        -ResourceGroupName $ResourceGroupName `
        -CollectionName $rpCollectionName `
        -RestorePointName $rpName `
        -ConsistencyMode 'CrashConsistent'
    
    # Get disk restore point IDs
    $restorePointData.DiskRestorePoints = Get-DiskRestorePointIds `
        -ResourceGroupName $ResourceGroupName `
        -CollectionName $rpCollectionName `
        -RestorePointName $rpName `
        -SourceVM $vmConfig
}
else {
    Write-Info "[WhatIf] Would create restore point collection '$rpCollectionName'."
    Write-Info "[WhatIf] Would create restore point '$rpName'."
}

Write-Success "VM restore point created."

#endregion

#region Step 6: Create Zonal Disks from Restore Points
Write-StepHeader "6" "Create Zonal Disks from Restore Points"

$newDisks = @{
    OsDisk    = $null
    DataDisks = @()
}

if ($PSCmdlet.ShouldProcess("OS Disk", "Create zonal disk in zone $TargetZone")) {
    # Validate that disk restore points were retrieved
    if ($null -eq $restorePointData.DiskRestorePoints -or $restorePointData.DiskRestorePoints.Count -eq 0) {
        throw "No disk restore points were retrieved. The restore point may not have been created successfully or the SourceMetadata is missing."
    }
    
    # Validate OS disk info exists
    if ($null -eq $diskInfo -or $null -eq $diskInfo.OsDisk -or [string]::IsNullOrEmpty($diskInfo.OsDisk.Name)) {
        throw "OS disk information is missing or invalid. Cannot proceed with disk creation."
    }
    
    # Determine new disk name - use suffix if same RG to avoid conflict
    $newOsDiskName = if ($sameResourceGroup) {
        "$($diskInfo.OsDisk.Name)-z$TargetZone"
    } else {
        $diskInfo.OsDisk.Name
    }
    
    # Use target SKU if specified, otherwise keep source SKU
    $osDiskTargetSku = $TargetOsDiskSku ? $TargetOsDiskSku : $diskInfo.OsDisk.Sku
    
    # Get disk restore point ID for OS disk
    $osDiskRpId = $restorePointData.DiskRestorePoints[$diskInfo.OsDisk.Name]
    if (-not $osDiskRpId) {
        Write-Warning "Available disk restore points: $($restorePointData.DiskRestorePoints.Keys -join ', ')"
        throw "Could not find disk restore point for OS disk '$($diskInfo.OsDisk.Name)'"
    }
    
    $osDiskParams = Get-ZonalDiskParams `
        -DiskRestorePointId $osDiskRpId `
        -NewDiskName $newOsDiskName `
        -TargetResourceGroupName $TargetResourceGroupName `
        -Location $vmConfig.Location `
        -Zone $TargetZone `
        -SkuName $osDiskTargetSku `
        -SourceSkuName $diskInfo.OsDisk.Sku `
        -DiskInfo $diskInfo.OsDisk
    
    $newDisks.OsDisk = New-ZonalDiskFromRestorePoint @osDiskParams
}
else {
    Write-Info "[WhatIf] Would create zonal OS disk in zone $TargetZone."
}

# Create data disks (with optional parallelism)
if ($diskInfo.DataDisks.Count -gt 0) {
    if ($PSCmdlet.ShouldProcess("$($diskInfo.DataDisks.Count) data disks", "Create zonal disks in zone $TargetZone")) {
        
        # Prepare disk creation parameters for all data disks
        $dataDiskJobs = @()
        foreach ($dataDisk in $diskInfo.DataDisks) {
            # Determine new disk name - use suffix if same RG to avoid conflict
            $newDataDiskName = if ($sameResourceGroup) {
                "$($dataDisk.Name)-z$TargetZone"
            } else {
                $dataDisk.Name
            }
            
            # Use target SKU if specified, otherwise keep source SKU
            $dataDiskTargetSku = $TargetDataDiskSku ? $TargetDataDiskSku : $dataDisk.Sku
            
            # Get disk restore point ID for this data disk
            $dataDiskRpId = $restorePointData.DiskRestorePoints[$dataDisk.Name]
            if (-not $dataDiskRpId) {
                throw "Could not find disk restore point for data disk '$($dataDisk.Name)'"
            }
            
            $dataDiskJobs += @{
                OriginalName = $dataDisk.Name
                NewDiskName  = $newDataDiskName
                Lun          = $dataDisk.Lun
                Caching      = $dataDisk.Caching
                Params       = Get-ZonalDiskParams `
                    -DiskRestorePointId $dataDiskRpId `
                    -NewDiskName $newDataDiskName `
                    -TargetResourceGroupName $TargetResourceGroupName `
                    -Location $vmConfig.Location `
                    -Zone $TargetZone `
                    -SkuName $dataDiskTargetSku `
                    -SourceSkuName $dataDisk.Sku `
                    -DiskInfo $dataDisk
            }
        }
        
        if ($ParallelDiskCreation -gt 1 -and $dataDiskJobs.Count -gt 1) {
            # Parallel disk creation
            Write-Info "Creating $($dataDiskJobs.Count) data disks in parallel (throttle: $ParallelDiskCreation)..."
            
            $createdDisks = $dataDiskJobs | ForEach-Object -ThrottleLimit $ParallelDiskCreation -Parallel {
                # Import required module in the parallel runspace
                Import-Module Az.Compute -ErrorAction SilentlyContinue
                
                $job = $_
                $params = $job.Params
                
                # Build disk config
                $diskConfigParams = @{
                    Location        = $params.Location
                    Zone            = $params.Zone
                    SkuName         = $params.SkuName
                    CreateOption    = 'Restore'
                    SourceResourceId = $params.DiskRestorePointId
                }
                if ($params.DiskEncryptionSetId) {
                    $diskConfigParams.DiskEncryptionSetId = $params.DiskEncryptionSetId
                }
                
                $diskConfig = New-AzDiskConfig @diskConfigParams
                
                if ($params.DiskSizeGB -and $params.DiskSizeGB -gt 0) {
                    $diskConfig.DiskSizeGB = $params.DiskSizeGB
                }
                if ($params.DiskIOPSReadWrite -and $params.DiskIOPSReadWrite -gt 0) {
                    $diskConfig.DiskIOPSReadWrite = $params.DiskIOPSReadWrite
                }
                if ($params.DiskMBpsReadWrite -and $params.DiskMBpsReadWrite -gt 0) {
                    $diskConfig.DiskMBpsReadWrite = $params.DiskMBpsReadWrite
                }
                if ($params.Tier) {
                    $diskConfig.Tier = $params.Tier
                }
                if ($params.LogicalSectorSize -and $params.LogicalSectorSize -gt 0) {
                    if ($null -ne $diskConfig.CreationData) {
                        $diskConfig.CreationData.LogicalSectorSize = $params.LogicalSectorSize
                    }
                }
                if ($params.Tags -and $params.Tags.Count -gt 0) {
                    if ($null -eq $diskConfig.Tags) {
                        $diskConfig.Tags = @{}
                    }
                    foreach ($key in $params.Tags.Keys) {
                        $diskConfig.Tags[$key] = $params.Tags[$key]
                    }
                }
                
                # Check if disk already exists
                $existingDisk = Get-AzDisk -ResourceGroupName $params.TargetResourceGroupName -DiskName $params.NewDiskName -ErrorAction SilentlyContinue
                if ($existingDisk) {
                    return @{
                        OriginalName = $job.OriginalName
                        NewDiskName  = $job.NewDiskName
                        Lun          = $job.Lun
                        Caching      = $job.Caching
                        Disk         = $existingDisk
                        Status       = 'Existing'
                    }
                }
                
                # Create disk with retry
                $maxRetries = $params.MaxRetries
                $retryCount = 0
                $lastError = $null
                
                while ($retryCount -lt $maxRetries) {
                    try {
                        $newDisk = New-AzDisk -ResourceGroupName $params.TargetResourceGroupName -DiskName $params.NewDiskName -Disk $diskConfig
                        return @{
                            OriginalName = $job.OriginalName
                            NewDiskName  = $job.NewDiskName
                            Lun          = $job.Lun
                            Caching      = $job.Caching
                            Disk         = $newDisk
                            Status       = 'Created'
                        }
                    }
                    catch {
                        $lastError = $_
                        $retryCount++
                        if ($retryCount -lt $maxRetries) {
                            Start-Sleep -Seconds 30
                        }
                    }
                }
                
                return @{
                    OriginalName = $job.OriginalName
                    NewDiskName  = $job.NewDiskName
                    Lun          = $job.Lun
                    Caching      = $job.Caching
                    Disk         = $null
                    Status       = 'Failed'
                    Error        = $lastError.Exception.Message
                }
            }
            
            # Process results
            foreach ($result in $createdDisks) {
                if ($result.Status -eq 'Failed') {
                    throw "Failed to create disk '$($result.NewDiskName)': $($result.Error)"
                }
                Write-Success "Disk '$($result.NewDiskName)' $($result.Status.ToLower())."
                $newDisks.DataDisks += @{
                    Disk    = $result.Disk
                    Lun     = $result.Lun
                    Caching = $result.Caching
                }
            }
        }
        else {
            # Sequential disk creation (original behavior)
            foreach ($job in $dataDiskJobs) {
                $newDataDisk = New-ZonalDiskFromRestorePoint @($job.Params)
                $newDisks.DataDisks += @{
                    Disk    = $newDataDisk
                    Lun     = $job.Lun
                    Caching = $job.Caching
                }
            }
        }
    }
    else {
        foreach ($dataDisk in $diskInfo.DataDisks) {
            Write-Info "[WhatIf] Would create zonal data disk '$($dataDisk.Name)' in zone $TargetZone."
        }
    }
}

Write-Success "All zonal disks created."

#endregion

#region Step 7: Create New NIC
Write-StepHeader "7" "Create New NIC"

# Use a different NIC name if same resource group to avoid conflict
$newNicName = if ($sameResourceGroup) {
    "$($nicConfig.Name)-z$TargetZone"
} else {
    $nicConfig.Name
}

Write-Info "Creating new NIC based on source NIC configuration..."
Write-Detail "Source NIC: $($nicConfig.Name)"
Write-Detail "New NIC: $newNicName"
Write-Detail "New NIC will get a dynamic IP assigned by Azure"

if ($PSCmdlet.ShouldProcess($newNicName, "Create new NIC")) {
    # Create new NIC with dynamic IP
    $newNic = Copy-NetworkInterfaceConfig `
        -SourceNicConfig $nicConfig `
        -NewNicName $newNicName `
        -TargetResourceGroupName $TargetResourceGroupName
    
    $newNicIp = ($newNic.IpConfigurations | Where-Object { $_.Primary -eq $true }).PrivateIpAddress
    Write-Success "New NIC '$newNicName' created with IP '$newNicIp'."
}
else {
    Write-Info "[WhatIf] Would create new NIC '$newNicName' with dynamic IP."
    $newNicIp = "<dynamic>"
}

#endregion

#region Step 8: Create New VM
Write-StepHeader "8" "Create New Zonal VM"

if ($PSCmdlet.ShouldProcess($NewVMName, "Create zonal VM in zone $TargetZone")) {
    # Create VM configuration - include PPG if specified
    if ($script:targetPPGObject) {
        $newVmConfig = New-AzVMConfig `
            -VMName $NewVMName `
            -VMSize $vmConfig.HardwareProfile.VmSize `
            -Zone $TargetZone `
            -ProximityPlacementGroupId $script:targetPPGObject.Id
        Write-Detail "VM will be assigned to PPG: $($script:targetPPGObject.Name)"
    }
    else {
        $newVmConfig = New-AzVMConfig `
            -VMName $NewVMName `
            -VMSize $vmConfig.HardwareProfile.VmSize `
            -Zone $TargetZone
    }
    
    # Set OS disk
    $osType = $diskInfo.OsDisk.OsType
    $osDiskCaching = $diskInfo.OsDisk.Caching
    
    # For PremiumV2_LRS or UltraSSD_LRS, force caching to None (check TARGET SKU)
    $targetOsSku = $TargetOsDiskSku ? $TargetOsDiskSku : $diskInfo.OsDisk.Sku
    if ($targetOsSku -in @('PremiumV2_LRS', 'UltraSSD_LRS')) {
        $osDiskCaching = 'None'
    }
    
    if ($osType -eq 'Windows') {
        $newVmConfig = Set-AzVMOSDisk `
            -VM $newVmConfig `
            -Name $newDisks.OsDisk.Name `
            -ManagedDiskId $newDisks.OsDisk.Id `
            -CreateOption Attach `
            -Windows `
            -Caching $osDiskCaching `
            -DeleteOption Delete
    }
    else {
        $newVmConfig = Set-AzVMOSDisk `
            -VM $newVmConfig `
            -Name $newDisks.OsDisk.Name `
            -ManagedDiskId $newDisks.OsDisk.Id `
            -CreateOption Attach `
            -Linux `
            -Caching $osDiskCaching `
            -DeleteOption Delete
    }
    
    # Attach data disks
    foreach ($dataDiskEntry in $newDisks.DataDisks) {
        $dataDiskCaching = $dataDiskEntry.Caching
        $dataDisk = $dataDiskEntry.Disk
        
        # For PremiumV2 or Ultra, force caching to None (check actual disk SKU which reflects target)
        if ($dataDisk.Sku.Name -in @('PremiumV2_LRS', 'UltraSSD_LRS')) {
            $dataDiskCaching = 'None'
        }
        
        $newVmConfig = Add-AzVMDataDisk `
            -VM $newVmConfig `
            -Name $dataDisk.Name `
            -ManagedDiskId $dataDisk.Id `
            -Lun $dataDiskEntry.Lun `
            -CreateOption Attach `
            -Caching $dataDiskCaching `
            -DeleteOption Delete
    }
    
    # Add NIC (with delete option so NIC is deleted when VM is deleted)
    $newVmConfig = Add-AzVMNetworkInterface -VM $newVmConfig -Id $newNic.Id -Primary -DeleteOption Delete
    
    # Set boot diagnostics
    $bootDiagEnabled = $vmConfig.DiagnosticsProfile -and $vmConfig.DiagnosticsProfile.BootDiagnostics -and $vmConfig.DiagnosticsProfile.BootDiagnostics.Enabled
    if ($bootDiagEnabled) {
        $storageUri = $vmConfig.DiagnosticsProfile.BootDiagnostics.StorageUri
        if ($storageUri) {
            $newVmConfig = Set-AzVMBootDiagnostic `
                -VM $newVmConfig `
                -Enable `
                -StorageAccountUri $storageUri
        }
        else {
            $newVmConfig = Set-AzVMBootDiagnostic -VM $newVmConfig -Enable
        }
    }
    else {
        $newVmConfig = Set-AzVMBootDiagnostic -VM $newVmConfig -Disable
    }
    
    # Set additional capabilities
    # Enable UltraSSD if: source had it enabled OR we're converting any disk to UltraSSD_LRS
    $needsUltraSSD = $false
    
    # Check if source VM had UltraSSD enabled
    if ($vmConfig.AdditionalCapabilities -and $vmConfig.AdditionalCapabilities.UltraSSDEnabled) {
        $needsUltraSSD = $true
    }
    
    # Check if target OS disk SKU is Ultra SSD
    if ($TargetOsDiskSku -eq 'UltraSSD_LRS') {
        $needsUltraSSD = $true
    }
    
    # Check if target data disk SKU is Ultra SSD
    if ($TargetDataDiskSku -eq 'UltraSSD_LRS') {
        $needsUltraSSD = $true
    }
    
    # Check if any source disk is already Ultra SSD (and we're keeping it)
    if ($diskInfo.OsDisk.Sku -eq 'UltraSSD_LRS' -or ($diskInfo.DataDisks | Where-Object { $_.Sku -eq 'UltraSSD_LRS' })) {
        $needsUltraSSD = $true
    }
    
    if ($needsUltraSSD) {
        $newVmConfig.AdditionalCapabilities = New-Object Microsoft.Azure.Management.Compute.Models.AdditionalCapabilities
        $newVmConfig.AdditionalCapabilities.UltraSSDEnabled = $true
        Write-Host "  Ultra SSD capability: Enabled" -ForegroundColor Gray
    }
    
    # Set license type
    if ($vmConfig.LicenseType) {
        $newVmConfig.LicenseType = $vmConfig.LicenseType
    }
    
    # Set security profile
    $securityType = $vmConfig.SecurityProfile?.SecurityType?.ToString()
    if ($securityType) {
        if ($securityType -eq 'TrustedLaunch') {
            $newVmConfig = Set-AzVMSecurityProfile -VM $newVmConfig -SecurityType $securityType
            
            if ($vmConfig.SecurityProfile.UefiSettings) {
                $newVmConfig = Set-AzVMUefi `
                    -VM $newVmConfig `
                    -EnableVtpm $vmConfig.SecurityProfile.UefiSettings.VTpmEnabled `
                    -EnableSecureBoot $vmConfig.SecurityProfile.UefiSettings.SecureBootEnabled
            }
        }
    }
    
    # Set encryption at host (if enabled on source VM)
    if ($vmConfig.SecurityProfile?.EncryptionAtHost -eq $true) {
        $newVmConfig.SecurityProfile ??= New-Object Microsoft.Azure.Management.Compute.Models.SecurityProfile
        $newVmConfig.SecurityProfile.EncryptionAtHost = $true
        Write-Host "  Encryption at host: Enabled" -ForegroundColor Gray
    }
    
    # Set identity
    $identityType = $vmConfig.Identity?.Type?.ToString()
    if ($identityType) {
        $newVmConfig.Identity = New-Object Microsoft.Azure.Management.Compute.Models.VirtualMachineIdentity
        
        if ($identityType -eq 'SystemAssigned') {
            $newVmConfig.Identity.Type = 'SystemAssigned'
        }
        elseif ($vmConfig.Identity.UserAssignedIdentities -and $vmConfig.Identity.UserAssignedIdentities.Count -gt 0) {
            # Build user identities dictionary for UserAssigned or SystemAssigned+UserAssigned
            $userIdentities = @{}
            foreach ($identityId in $vmConfig.Identity.UserAssignedIdentities.Keys) {
                $userIdentities[$identityId] = New-Object Microsoft.Azure.Management.Compute.Models.UserAssignedIdentitiesValue
            }
            $newVmConfig.Identity.UserAssignedIdentities = $userIdentities
            
            if ($identityType -eq 'UserAssigned') {
                $newVmConfig.Identity.Type = 'UserAssigned'
            }
            elseif ($identityType -like '*UserAssigned*') {
                $newVmConfig.Identity.Type = 'SystemAssignedUserAssigned'
            }
        }
    }
    
    # Set tags
    if ($vmConfig.Tags -and $vmConfig.Tags.Count -gt 0) {
        if ($null -eq $newVmConfig.Tags) {
            $newVmConfig.Tags = @{}
        }
        foreach ($key in $vmConfig.Tags.Keys) {
            $newVmConfig.Tags[$key] = $vmConfig.Tags[$key]
        }
    }
    
    # Set priority and eviction policy for Spot VMs
    $priority = $vmConfig.Priority?.ToString() ?? "Regular"
    if ($priority -eq 'Spot') {
        $newVmConfig.Priority = 'Spot'
        $newVmConfig.EvictionPolicy = $vmConfig.EvictionPolicy?.ToString()
        if ($vmConfig.BillingProfile?.MaxPrice) {
            $newVmConfig.BillingProfile = New-Object Microsoft.Azure.Management.Compute.Models.BillingProfile
            $newVmConfig.BillingProfile.MaxPrice = $vmConfig.BillingProfile.MaxPrice
        }
    }
    
    Write-Info "Creating VM '$NewVMName' in zone $TargetZone..."
    New-AzVM `
        -ResourceGroupName $TargetResourceGroupName `
        -Location $vmConfig.Location `
        -VM $newVmConfig | Out-Null
    
    Write-Success "VM '$NewVMName' created successfully in zone $TargetZone."
    if ($script:targetPPGObject) {
        Write-Success "VM assigned to Proximity Placement Group: $($script:targetPPGObject.Name)"
    }
}
else {
    Write-Info "[WhatIf] Would create VM '$NewVMName' in zone $TargetZone."
    if ($script:targetPPGObject) {
        Write-Info "[WhatIf] Would assign VM to PPG: $($script:targetPPGObject.Name)"
    }
}

#endregion

#region Step 9: List Source VM Extensions
Write-StepHeader "9" "Source VM Extensions"

if ($sourceExtensions -and $sourceExtensions.Count -gt 0) {
    Write-Warning "The source VM had the following extensions installed:"
    Write-Host ""
    foreach ($ext in $sourceExtensions) {
        Write-Host "  - $($ext.Name)" -ForegroundColor White
        Write-Detail "Publisher: $($ext.Publisher)"
        Write-Detail "Type: $($ext.ExtensionType)"
        Write-Detail "Version: $($ext.TypeHandlerVersion)"
        Write-Host ""
    }
    Write-Warning "Extensions are NOT automatically copied to the new VM."
    Write-Warning "They may be installed via Azure Policy or other automation, or you can install them manually."
}
else {
    Write-Success "No extensions were installed on the source VM."
}

#endregion

#region Step 10: Cleanup Restore Point Collection
Write-StepHeader "10" "Cleanup Restore Point Collection"

if ($PSCmdlet.ShouldProcess("Restore Point Collection", "Delete temporary restore point collection")) {
    # Delete the restore point collection (this also deletes all restore points within it)
    if ($restorePointData.CollectionName) {
        Write-Info "Deleting restore point collection '$($restorePointData.CollectionName)'..."
        Remove-AzRestorePointCollection -ResourceGroupName $ResourceGroupName -Name $restorePointData.CollectionName | Out-Null
        Write-Success "Restore point collection deleted."
    }
}
else {
    Write-Info "[WhatIf] Would delete restore point collection '$($restorePointData.CollectionName)'."
}

#endregion

#region Summary
Write-Host "`n"
Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║                              OPERATION COMPLETE                              ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host "`n"

# Determine source zone info
$sourceZoneDisplay = ($vmConfig.Zones -and $vmConfig.Zones.Count -gt 0) ? "Zone $($vmConfig.Zones[0])" : "Regional (no zone)"

Write-Host "Source Resources (UNCHANGED) - $sourceZoneDisplay :" -ForegroundColor Cyan
Write-Host "  VM:                     $VMName in $ResourceGroupName (Stopped/Deallocated)" -ForegroundColor Gray
Write-Host "  OS Disk:                $($diskInfo.OsDisk.Name) ($($diskInfo.OsDisk.Sku))" -ForegroundColor Gray
foreach ($dd in $diskInfo.DataDisks) {
    Write-Host "  Data Disk:              $($dd.Name) ($($dd.Sku))" -ForegroundColor Gray
}
Write-Host "  NIC:                    $($nicConfig.Name) (IP: $sourceIpAddress)" -ForegroundColor Gray
if ($sourcePPGId) {
    $sourcePpgNameForDisplay = $sourcePPGId.Split('/')[-1]
    Write-Host "  PPG:                    $sourcePpgNameForDisplay" -ForegroundColor Gray
}
Write-Host "`n"

# For new resources, use actual names if created, otherwise use expected names from source
$newOsDiskName = $newDisks.OsDisk ? $newDisks.OsDisk.Name : ($sameResourceGroup ? "$($diskInfo.OsDisk.Name)-z$TargetZone" : $diskInfo.OsDisk.Name)
$targetOsDiskSkuDisplay = $TargetOsDiskSku ? $TargetOsDiskSku : $diskInfo.OsDisk.Sku

Write-Host "New Resources Created - Zone $TargetZone :" -ForegroundColor Cyan
Write-Host "  VM:                     $NewVMName in $TargetResourceGroupName" -ForegroundColor Gray
Write-Host "  OS Disk:                $newOsDiskName ($targetOsDiskSkuDisplay)" -ForegroundColor Gray
foreach ($dd in $diskInfo.DataDisks) {
    $newDataDiskName = if ($sameResourceGroup) { "$($dd.Name)-z$TargetZone" } else { $dd.Name }
    $targetDataDiskSkuDisplay = $TargetDataDiskSku ? $TargetDataDiskSku : $dd.Sku
    Write-Host "  Data Disk:              $newDataDiskName ($targetDataDiskSkuDisplay)" -ForegroundColor Gray
}
Write-Host "  NIC:                    $newNicName (IP: $newNicIp)" -ForegroundColor Gray
# Show PPG status: if source had PPG, show whether it was used or skipped
if ($sourcePPGId) {
    if ($script:targetPPGObject) {
        Write-Host "  PPG:                    $($script:targetPPGObject.Name)" -ForegroundColor Gray
    } else {
        Write-Host "  PPG:                    -- (source PPG not compatible with Zone $TargetZone)" -ForegroundColor Gray
    }
}
Write-Host "`n"

Write-Host "IMPORTANT:" -ForegroundColor Red
Write-Host "  - The source VM is stopped but NOT deleted or modified" -ForegroundColor White
Write-Host "  - The new VM has a DIFFERENT IP address than the source" -ForegroundColor Yellow
Write-Host "  - Update DNS records or firewall rules if needed" -ForegroundColor Yellow
if ($sourcePPGId -and -not $script:targetPPGObject) {
    Write-Host "  - New VM was NOT added to source PPG (zone incompatibility)" -ForegroundColor Yellow
}
if ($sourceExtensions -and $sourceExtensions.Count -gt 0) {
    Write-Host "  - Extensions from the source VM were NOT installed (see Step 9)" -ForegroundColor Yellow
}
Write-Host "  - Review the new VM before deleting the source resources" -ForegroundColor White
Write-Host "`n"

#endregion
