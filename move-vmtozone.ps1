<#
.SYNOPSIS
    Creates a copy of an Azure VM in a target availability zone within a new resource group.

.DESCRIPTION
    This script creates a zonal copy of an Azure VM (regional or zonal) into a specified
    availability zone and a DIFFERENT target resource group. The source VM and all its 
    resources remain untouched. The script:
    - Creates snapshots of all disks (in target resource group)
    - Creates new zonal disks from snapshots in the target resource group
    - Creates a new NIC with all configurations copied from the source
    - Creates the new VM in the target resource group

    IMPORTANT: This script does NOT delete or modify any source resources.
    The target resource group MUST be different from the source resource group.
    
    PREREQUISITE: Set your Azure context before running this script using:
    Set-AzContext -SubscriptionId "your-subscription-id"

.PARAMETER ResourceGroupName
    The resource group name of the source VM.

.PARAMETER VMName
    The name of the source VM to copy.

.PARAMETER TargetResourceGroupName
    The resource group where the new VM and all resources will be created.
    This resource group must already exist and MUST be different from the source resource group.

.PARAMETER TargetZone
    The target availability zone (1, 2, or 3).

.PARAMETER NewVMName
    Optional. The name for the new VM. Defaults to the same name as the source VM
    (since it will be in a different resource group).

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

.PARAMETER WhatIf
    Optional. If specified, shows what would happen without making any changes.

.EXAMPLE
    .\move-vmtozone.ps1 -ResourceGroupName "my-source-rg" -VMName "my-vm" `
        -TargetResourceGroupName "my-target-rg" -TargetZone 2
    # Creates 'my-vm' in 'my-target-rg' in zone 2 (same VM name, different RG)

.EXAMPLE
    .\move-vmtozone.ps1 -ResourceGroupName "my-source-rg" -VMName "my-vm" `
        -TargetResourceGroupName "my-target-rg" -TargetZone 1 -NewVMName "my-vm-new" -WhatIf
    # Creates 'my-vm-new' in 'my-target-rg' in zone 1 with WhatIf preview

.NOTES
    Requires: PowerShell 7.0+, Az.Compute, Az.Network, Az.Resources modules
    
    IP ADDRESS HANDLING:
    - The new NIC will be assigned a NEW dynamic IP address by Azure
    - The source NIC keeps its IP (source resources are NOT modified)
    - You may need to update DNS records or firewall rules after migration
    
    LIMITATIONS:
    - VMs with multiple NICs are not supported
    - The target resource group must already exist and be DIFFERENT from source
    - New VM will have a DIFFERENT IP address than the source
    - VM extensions are NOT automatically installed on the new VM
    - All new resources (disks, NIC, VM) will have the same names as source (in different RG)
    - Proximity Placement Groups: New VM is only added to source PPG if the PPG is compatible
      with the target zone. PPGs with running regional VMs or VMs in different zones are skipped.
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
    
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
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
    [string]$TargetDataDiskSku
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

function Get-VMDiskInfo {
    <#
    .SYNOPSIS
        Gets disk information including SKU and encryption settings from the source VM.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine]$VM
    )
    
    # Get OS disk details
    $osDisk = Get-AzDisk -ResourceGroupName $VM.ResourceGroupName -DiskName $VM.StorageProfile.OsDisk.Name
    $osDiskInfo = @{
        Name                 = $VM.StorageProfile.OsDisk.Name
        Caching              = $VM.StorageProfile.OsDisk.Caching.ToString()
        OsType               = $VM.StorageProfile.OsDisk.OsType.ToString()
        Sku                  = $osDisk.Sku.Name
        DiskSizeGB           = $osDisk.DiskSizeGB
        DiskIOPSReadWrite    = $osDisk.DiskIOPSReadWrite
        DiskMBpsReadWrite    = $osDisk.DiskMBpsReadWrite
        Tier                 = $osDisk.Tier
        LogicalSectorSize    = $osDisk.CreationData.LogicalSectorSize
        DiskEncryptionSetId  = $osDisk.Encryption?.DiskEncryptionSetId
    }
    
    # Get data disk details
    $dataDisksInfo = @()
    foreach ($dataDisk in $VM.StorageProfile.DataDisks) {
        $disk = Get-AzDisk -ResourceGroupName $VM.ResourceGroupName -DiskName $dataDisk.Name
        $dataDisksInfo += @{
            Name                 = $dataDisk.Name
            Lun                  = $dataDisk.Lun
            Caching              = $dataDisk.Caching.ToString()
            Sku                  = $disk.Sku.Name
            DiskSizeGB           = $disk.DiskSizeGB
            DiskIOPSReadWrite    = $disk.DiskIOPSReadWrite
            DiskMBpsReadWrite    = $disk.DiskMBpsReadWrite
            Tier                 = $disk.Tier
            LogicalSectorSize    = $disk.CreationData.LogicalSectorSize
            DiskEncryptionSetId  = $disk.Encryption?.DiskEncryptionSetId
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

function New-DiskSnapshot {
    <#
    .SYNOPSIS
        Creates an incremental snapshot of a disk.
        For Ultra Disks and Premium SSD v2, uses instant access snapshots when available.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$DiskName,
        [Parameter(Mandatory = $true)]
        [string]$DiskResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$SnapshotResourceGroupName,
        [Parameter(Mandatory = $true)]
        [string]$Location,
        [Parameter(Mandatory = $false)]
        [int]$TimeoutMinutes = 30,
        [Parameter(Mandatory = $false)]
        [int]$InstantAccessDurationMinutes = 300
    )
    
    $disk = Get-AzDisk -ResourceGroupName $DiskResourceGroupName -DiskName $DiskName
    $diskSku = $disk.Sku.Name
    
    # Generate snapshot name - Azure has 80 char limit for snapshot names
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $baseName = $DiskName
    # Truncate base name if needed to fit within 80 chars (leaving room for -snap- and timestamp)
    $maxBaseNameLength = 80 - "-snap-".Length - $timestamp.Length
    if ($baseName.Length -gt $maxBaseNameLength) {
        $baseName = $baseName.Substring(0, $maxBaseNameLength)
    }
    $snapshotName = "$baseName-snap-$timestamp"
    
    # Check if this is an Ultra Disk or Premium SSD v2 - they support instant access snapshots
    $useInstantAccess = $diskSku -in @('UltraSSD_LRS', 'PremiumV2_LRS')
    
    if ($useInstantAccess) {
        Write-Info "Disk '$DiskName' is $diskSku - using instant access snapshot for faster disk creation..."
        $snapshotConfig = New-AzSnapshotConfig `
            -SourceUri $disk.Id `
            -Location $Location `
            -CreateOption Copy `
            -Incremental `
            -InstantAccessDurationMinutes $InstantAccessDurationMinutes
    }
    else {
        $snapshotConfig = New-AzSnapshotConfig `
            -SourceUri $disk.Id `
            -Location $Location `
            -CreateOption Copy `
            -Incremental
    }
    
    Write-Info "Creating incremental snapshot '$snapshotName' for disk '$DiskName'..."
    $snapshot = New-AzSnapshot -ResourceGroupName $SnapshotResourceGroupName -SnapshotName $snapshotName -Snapshot $snapshotConfig
    
    # Wait for snapshot to be ready
    # For instant access snapshots (Ultra/PremiumV2), we can use them immediately when in InstantAccess or AvailableWithInstantAccess state
    # For regular snapshots, we wait for SnapshotAccessState = 'Available'
    $startTime = Get-Date
    $timeout = New-TimeSpan -Minutes $TimeoutMinutes
    $retryDelay = 5
    $maxRetryDelay = 30
    
    while ($true) {
        $currentSnapshot = Get-AzSnapshot -ResourceGroupName $SnapshotResourceGroupName -SnapshotName $snapshotName
        
        if ($currentSnapshot.ProvisioningState -eq 'Failed') {
            throw "Snapshot '$snapshotName' failed. State: $($currentSnapshot.ProvisioningState)"
        }
        
        if ((Get-Date) - $startTime -gt $timeout) {
            throw "Timeout waiting for snapshot '$snapshotName' to complete. Current state: $($currentSnapshot.ProvisioningState), AccessState: $($currentSnapshot.SnapshotAccessState)"
        }
        
        $provisioningComplete = $currentSnapshot.ProvisioningState -eq 'Succeeded'
        $accessState = $currentSnapshot.SnapshotAccessState
        
        # For instant access snapshots, we can proceed immediately when in InstantAccess or AvailableWithInstantAccess state
        # For regular snapshots, we need to wait for Available state
        if ($useInstantAccess) {
            $snapshotReady = $accessState -in @('InstantAccess', 'AvailableWithInstantAccess', 'Available')
        }
        else {
            $snapshotReady = ($null -eq $accessState) -or ($accessState -eq 'Available')
        }
        
        if ($provisioningComplete -and $snapshotReady) {
            if ($useInstantAccess -and $accessState -in @('InstantAccess', 'AvailableWithInstantAccess')) {
                Write-Success "Instant access snapshot '$snapshotName' ready (AccessState: $accessState)."
            }
            else {
                Write-Success "Snapshot '$snapshotName' completed successfully."
            }
            break
        }
        
        $statusMsg = "Provisioning: $($currentSnapshot.ProvisioningState)"
        if ($null -ne $accessState) {
            $statusMsg += ", AccessState: $accessState"
        }
        Write-Detail "Waiting for snapshot... ($statusMsg)"
        
        Start-Sleep -Seconds $retryDelay
        $retryDelay = [Math]::Min($retryDelay * 1.5, $maxRetryDelay)
    }
    
    return $snapshot
}

function New-ZonalDiskFromSnapshot {
    <#
    .SYNOPSIS
        Creates a new zonal managed disk from a snapshot in the target resource group.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$SnapshotId,
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
            -CreateOption Copy `
            -SourceResourceId $SnapshotId `
            -DiskEncryptionSetId $DiskEncryptionSetId
    }
    else {
        $diskConfig = New-AzDiskConfig `
            -Location $Location `
            -Zone $Zone `
            -SkuName $SkuName `
            -CreateOption Copy `
            -SourceResourceId $SnapshotId
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
        $diskConfig.CreationData.LogicalSectorSize = $LogicalSectorSize
    }
    
    if ($Tags -and $Tags.Count -gt 0) {
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
            Write-Info "Creating zonal disk '$NewDiskName' in zone $Zone (attempt $($retryCount + 1)/$MaxRetries)..."
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

function Get-TargetDiskName {
    <#
    .SYNOPSIS
        Returns the target disk name. Currently returns the same name as source
        since resources are created in a different resource group (no conflict).
        This function exists as an extension point for future naming customization.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$OriginalName
    )
    
    return $OriginalName
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
        Builds parameter hashtable for New-ZonalDiskFromSnapshot, adding optional params only if present.
    #>
    param(
        [Parameter(Mandatory)] [string]$SnapshotId,
        [Parameter(Mandatory)] [string]$NewDiskName,
        [Parameter(Mandatory)] [string]$TargetResourceGroupName,
        [Parameter(Mandatory)] [string]$Location,
        [Parameter(Mandatory)] [int]$Zone,
        [Parameter(Mandatory)] [string]$SkuName,
        [hashtable]$DiskInfo,
        [hashtable]$Tags
    )
    
    $params = @{
        SnapshotId              = $SnapshotId
        NewDiskName             = $NewDiskName
        TargetResourceGroupName = $TargetResourceGroupName
        Location                = $Location
        Zone                    = $Zone
        SkuName                 = $SkuName
    }
    
    # Add optional disk properties if present
    @('DiskSizeGB', 'DiskIOPSReadWrite', 'DiskMBpsReadWrite', 'Tier', 'LogicalSectorSize', 'DiskEncryptionSetId') | ForEach-Object {
        if ($DiskInfo.$_) { $params.$_ = $DiskInfo.$_ }
    }
    
    if ($Tags) { $params.Tags = $Tags }
    
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
    
    # Add tags
    if ($SourceNicConfig.Tags) {
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
Write-Host "╔══════════════════════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║           AZURE VM ZONAL COPY SCRIPT                                         ║" -ForegroundColor Magenta
Write-Host "║           Creates a copy of a VM in a target availability zone               ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host "`n"

# Verify Azure context is set
$currentContext = Get-AzContext
if (-not $currentContext -or -not $currentContext.Subscription) {
    throw "No Azure context set. Please run 'Set-AzContext -SubscriptionId <your-subscription-id>' before running this script."
}
Write-Info "Using subscription: $($currentContext.Subscription.Name) ($($currentContext.Subscription.Id))"

#region Step 1: Retrieve and Validate Source VM
Write-StepHeader "1" "Retrieve and Validate Source VM"

$vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status
if (-not $vm) {
    throw "VM '$VMName' not found in resource group '$ResourceGroupName'."
}

$vmConfig = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $VMName

# Check for multiple NICs
if ($vmConfig.NetworkProfile.NetworkInterfaces.Count -gt 1) {
    throw "VM '$VMName' has $($vmConfig.NetworkProfile.NetworkInterfaces.Count) NICs. This script only supports VMs with a single NIC."
}

Write-Success "VM '$VMName' found."
Write-Detail "Location: $($vmConfig.Location)"
Write-Detail "VM Size: $($vmConfig.HardwareProfile.VmSize)"
Write-Detail "Current Zone: $(($vmConfig.Zones -and $vmConfig.Zones.Count -gt 0) ? $vmConfig.Zones[0] : 'None (Regional)')"
Write-Detail "NICs: $($vmConfig.NetworkProfile.NetworkInterfaces.Count)"

# Validate target resource group is different from source
if ($TargetResourceGroupName -eq $ResourceGroupName) {
    throw "Target resource group must be different from source resource group. Source: '$ResourceGroupName', Target: '$TargetResourceGroupName'"
}

# Validate target resource group exists
$targetRg = Get-AzResourceGroup -Name $TargetResourceGroupName -ErrorAction SilentlyContinue
if (-not $targetRg) {
    throw "Target resource group '$TargetResourceGroupName' does not exist. Please create it first."
}
Write-Success "Target resource group '$TargetResourceGroupName' exists."

# Set default new VM name if not provided (defaults to same name since different RG)
if (-not $NewVMName) {
    $NewVMName = $VMName
}
Write-Detail "New VM Name: $NewVMName"

# Check if new VM already exists
$existingVM = Get-AzVM -ResourceGroupName $TargetResourceGroupName -Name $NewVMName -ErrorAction SilentlyContinue
if ($existingVM) {
    throw "A VM named '$NewVMName' already exists in resource group '$TargetResourceGroupName'."
}

# Check for Azure Disk Encryption (ADE)
Write-Info "Checking for Azure Disk Encryption (ADE)..."
$adeStatus = Get-AzVmDiskEncryptionStatus -ResourceGroupName $ResourceGroupName -VMName $VMName -ErrorAction SilentlyContinue
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
Write-Success "No Azure Disk Encryption (ADE) detected."

#endregion

#region Step 2: Gather Source VM Configuration
Write-StepHeader "2" "Gather Source VM Configuration"

Write-Info "Gathering disk information..."
$diskInfo = Get-VMDiskInfo -VM $vmConfig
Write-Success "Found OS disk and $($diskInfo.DataDisks.Count) data disk(s)."

Write-Info "Gathering NIC configuration..."
$nicConfig = Get-VMNicConfig -VM $vmConfig
Write-Success "NIC configuration gathered."

Write-Info "Gathering extension list..."
$sourceExtensions = @(Get-VMExtensionsList -VM $vmConfig)
Write-Success "Found $($sourceExtensions.Count) extension(s)."

#endregion

#region Step 3: Validate Disk Caching Settings
Write-StepHeader "3" "Validate Disk SKU and Caching Settings"

# Determine effective target SKUs
$effectiveOsDiskSku = $TargetOsDiskSku ? $TargetOsDiskSku : $diskInfo.OsDisk.Sku
$effectiveDataDiskSku = $TargetDataDiskSku  # May be null/empty, meaning use source SKU per disk

# Display SKU conversion info
if ($TargetOsDiskSku -and $TargetOsDiskSku -ne $diskInfo.OsDisk.Sku) {
    Write-Info "OS Disk SKU conversion: $($diskInfo.OsDisk.Sku) -> $TargetOsDiskSku"
} else {
    Write-Detail "OS Disk SKU: $($diskInfo.OsDisk.Sku) (unchanged)"
}

if ($TargetDataDiskSku) {
    Write-Info "Data Disk SKU conversion: all data disks will use $TargetDataDiskSku"
} else {
    Write-Detail "Data Disk SKU: each disk keeps source SKU"
}

$osDiskCaching = $diskInfo.OsDisk.Caching

# Validate OS disk caching - check against TARGET SKU (or source if not converting)
if ($effectiveOsDiskSku -in @('PremiumV2_LRS', 'UltraSSD_LRS')) {
    if ($osDiskCaching -ne 'None') {
        throw "OS Disk '$($diskInfo.OsDisk.Name)' will use $effectiveOsDiskSku which only supports Caching='None'. Current caching is '$osDiskCaching'. Please change the caching setting on the source disk before running this script."
    }
    Write-Success "OS Disk caching validated for $effectiveOsDiskSku."
}

# Validate data disk caching - check against TARGET SKU for each disk
foreach ($dataDisk in $diskInfo.DataDisks) {
    $targetDataSku = $effectiveDataDiskSku ?? $dataDisk.Sku
    if ($targetDataSku -in @('PremiumV2_LRS', 'UltraSSD_LRS')) {
        if ($dataDisk.Caching -ne 'None') {
            throw "Data Disk '$($dataDisk.Name)' will use $targetDataSku which only supports Caching='None'. Current caching is '$($dataDisk.Caching)'. Please change the caching setting on the source disk before running this script."
        }
    }
}

Write-Success "All disk caching settings validated."

# Validate Premium SSD v2 / Ultra SSD availability in target zone
$skusToValidate = @()

# Check OS disk target SKU
if ($effectiveOsDiskSku -in @('PremiumV2_LRS', 'UltraSSD_LRS')) {
    $skusToValidate += $effectiveOsDiskSku
}

# Check data disk target SKU
if ($effectiveDataDiskSku -in @('PremiumV2_LRS', 'UltraSSD_LRS')) {
    $skusToValidate += $effectiveDataDiskSku
}

# Also check source disks if keeping their SKU
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

# Validate each unique SKU
$skusToValidate = @($skusToValidate | Sort-Object -Unique)
foreach ($skuToValidate in $skusToValidate) {
    Write-Info "Checking $skuToValidate availability in zone $TargetZone..."
    $skuCheck = Test-DiskSkuAvailability -SkuName $skuToValidate -Location $vmConfig.Location -Zone $TargetZone
    
    if (-not $skuCheck.IsAvailable) {
        throw $skuCheck.Message
    }
    
    if ($skuCheck.AvailableZones.Count -gt 0) {
        Write-Success "$skuToValidate is available in zone $TargetZone (available zones: $($skuCheck.AvailableZones -join ', '))"
    } else {
        Write-Success "$skuToValidate is available in location '$($vmConfig.Location)'"
    }
}

#endregion

#region Step 4: Validate NIC Configuration
Write-StepHeader "4" "Validate NIC Configuration"

$primaryIpConfig = $nicConfig.IpConfigurations | Where-Object { $_.Primary -eq $true }
$sourceIpAddress = $primaryIpConfig.PrivateIpAddress
$sourceIpAllocation = $primaryIpConfig.PrivateIpAllocationMethod

Write-Success "Source NIC: $($nicConfig.Name)"
Write-Detail "IP Address: $sourceIpAddress ($sourceIpAllocation)"
Write-Info "New NIC will be assigned a different IP address by Azure (dynamic allocation)."

# Check for public IPs
$hasPublicIp = $false
foreach ($ipConfig in $nicConfig.IpConfigurations) {
    if ($ipConfig.PublicIpAddressId) {
        $hasPublicIp = $true
        Write-Warning "IP Configuration '$($ipConfig.Name)' has a Public IP attached."
    }
}

if ($hasPublicIp) {
    Write-Warning "The source VM has Public IP(s) attached. Public IPs will NOT be copied to the new NIC."
    Write-Warning "You will need to manually attach Public IPs to the new VM if required."
}
else {
    Write-Success "No Public IPs attached to the source NIC."
}

#endregion

#region Step 5: Validate VM Size Availability in Target Zone
Write-StepHeader "5" "Validate VM Size Availability in Target Zone"

$vmSize = $vmConfig.HardwareProfile.VmSize
$location = $vmConfig.Location

Write-Info "Checking if VM size '$vmSize' is available in zone $TargetZone..."

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

Write-Success "VM size '$vmSize' is available in zone $TargetZone."

#endregion

#region Step 6: Check for Proximity Placement Group
Write-StepHeader "6" "Check for Proximity Placement Group"

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
                    $stateInfo = if ($ppgVm.IsRunning) { ", Running" } else { ", Stopped" }
                    Write-Detail "  - $($ppgVm.Name) (Zone: $($ppgVm.Zone)$stateInfo)"
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
                Write-Success "PPG '$sourcePpgName' is not yet pinned to a zone - will be pinned to Zone $TargetZone."
            }
            Write-Success "New VM will be assigned to PPG '$sourcePpgName'."
            $script:targetPPGObject = $sourcePPG
        }
        else {
            # PPG is NOT compatible - warn user with specific reason
            Write-Host ""
            
            if ($ppgCheck.RunningRegionalVMs.Count -gt 0) {
                # Running regional VMs physically pin the PPG
                Write-Host "WARNING: PPG Physical Pinning Conflict!" -ForegroundColor Red
                Write-Host "  PPG '$sourcePpgName' has running regional (non-zonal) VMs:" -ForegroundColor Yellow
                foreach ($runningVm in $ppgCheck.RunningRegionalVMs) {
                    Write-Host "    - $runningVm" -ForegroundColor Yellow
                }
                Write-Host ""
                Write-Host "  Running regional VMs physically pin the PPG to specific hardware." -ForegroundColor Yellow
                Write-Host "  This hardware may not be in the target Zone $TargetZone." -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  The new VM will NOT be added to the source PPG." -ForegroundColor Yellow
                Write-Host ""
                Write-Warning "To use this PPG, first stop the regional VMs listed above, then re-run this script."
            }
            elseif ($ppgCheck.PinnedZone) {
                # Zonal VMs pin the PPG to a different zone
                Write-Host "WARNING: PPG Zone Mismatch!" -ForegroundColor Red
                Write-Host "  PPG '$sourcePpgName' is pinned to Zone $($ppgCheck.PinnedZone)" -ForegroundColor Yellow
                Write-Host "  Target zone for new VM is Zone $TargetZone" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  PPGs require all VMs to be in the same zone." -ForegroundColor Yellow
                Write-Host "  The new VM will NOT be added to the source PPG." -ForegroundColor Yellow
                Write-Host ""
                Write-Warning "To keep the VM in the same PPG, change the target zone to $($ppgCheck.PinnedZone)."
            }
            else {
                # Generic incompatibility
                Write-Host "WARNING: PPG Incompatible!" -ForegroundColor Red
                Write-Host "  $($ppgCheck.Message)" -ForegroundColor Yellow
                Write-Host ""
                Write-Host "  The new VM will NOT be added to the source PPG." -ForegroundColor Yellow
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

#region Step 7: Stop Source VM (for consistent snapshots)
Write-StepHeader "7" "Stop Source VM"

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

#region Step 8: Create Disk Snapshots
Write-StepHeader "8" "Create Disk Snapshots"

$snapshots = @{
    OsDisk    = $null
    DataDisks = @()
}

if ($PSCmdlet.ShouldProcess($diskInfo.OsDisk.Name, "Create snapshot")) {
    # OS Disk snapshot
    $osDiskSnapshot = New-DiskSnapshot `
        -DiskName $diskInfo.OsDisk.Name `
        -DiskResourceGroupName $ResourceGroupName `
        -SnapshotResourceGroupName $TargetResourceGroupName `
        -Location $vmConfig.Location
    
    $snapshots.OsDisk = $osDiskSnapshot
}
else {
    Write-Info "[WhatIf] Would create snapshot for OS disk '$($diskInfo.OsDisk.Name)'."
}

# Data Disk snapshots
foreach ($dataDisk in $diskInfo.DataDisks) {
    if ($PSCmdlet.ShouldProcess($dataDisk.Name, "Create snapshot")) {
        $dataDiskSnapshot = New-DiskSnapshot `
            -DiskName $dataDisk.Name `
            -DiskResourceGroupName $ResourceGroupName `
            -SnapshotResourceGroupName $TargetResourceGroupName `
            -Location $vmConfig.Location
        
        $snapshots.DataDisks += @{
            Snapshot       = $dataDiskSnapshot
            OriginalConfig = $dataDisk
        }
    }
    else {
        Write-Info "[WhatIf] Would create snapshot for data disk '$($dataDisk.Name)'."
    }
}

Write-Success "All snapshots created."

#endregion

#region Step 9: Create Zonal Disks from Snapshots
Write-StepHeader "9" "Create Zonal Disks from Snapshots"

$newDisks = @{
    OsDisk    = $null
    DataDisks = @()
}

if ($PSCmdlet.ShouldProcess("OS Disk", "Create zonal disk in zone $TargetZone")) {
    $newOsDiskName = Get-TargetDiskName -OriginalName $diskInfo.OsDisk.Name
    
    # Use target SKU if specified, otherwise keep source SKU
    $osDiskTargetSku = $TargetOsDiskSku ? $TargetOsDiskSku : $diskInfo.OsDisk.Sku
    
    $osDiskParams = Get-ZonalDiskParams `
        -SnapshotId $snapshots.OsDisk.Id `
        -NewDiskName $newOsDiskName `
        -TargetResourceGroupName $TargetResourceGroupName `
        -Location $vmConfig.Location `
        -Zone $TargetZone `
        -SkuName $osDiskTargetSku `
        -DiskInfo $diskInfo.OsDisk `
        -Tags $vmConfig.Tags
    
    $newDisks.OsDisk = New-ZonalDiskFromSnapshot @osDiskParams
}
else {
    Write-Info "[WhatIf] Would create zonal OS disk in zone $TargetZone."
}

# Create data disks
foreach ($dataDiskInfo in $snapshots.DataDisks) {
    $dataDisk = $dataDiskInfo.OriginalConfig
    
    if ($PSCmdlet.ShouldProcess($dataDisk.Name, "Create zonal disk in zone $TargetZone")) {
        $newDataDiskName = Get-TargetDiskName -OriginalName $dataDisk.Name
        
        # Use target SKU if specified, otherwise keep source SKU
        $dataDiskTargetSku = $TargetDataDiskSku ? $TargetDataDiskSku : $dataDisk.Sku
        
        $dataDiskParams = Get-ZonalDiskParams `
            -SnapshotId $dataDiskInfo.Snapshot.Id `
            -NewDiskName $newDataDiskName `
            -TargetResourceGroupName $TargetResourceGroupName `
            -Location $vmConfig.Location `
            -Zone $TargetZone `
            -SkuName $dataDiskTargetSku `
            -DiskInfo $dataDisk `
            -Tags $vmConfig.Tags
        
        $newDataDisk = New-ZonalDiskFromSnapshot @dataDiskParams
        $newDisks.DataDisks += @{
            Disk       = $newDataDisk
            Lun        = $dataDisk.Lun
            Caching    = $dataDisk.Caching
        }
    }
    else {
        Write-Info "[WhatIf] Would create zonal data disk '$($dataDisk.Name)' in zone $TargetZone."
    }
}

Write-Success "All zonal disks created."

#endregion

#region Step 10: Create New NIC
Write-StepHeader "10" "Create New NIC"

# Use the same NIC name since it's in a different resource group
$newNicName = $nicConfig.Name

Write-Info "Creating new NIC based on source NIC configuration..."
Write-Detail "Source NIC: $($nicConfig.Name)"
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

#region Step 11: Create New VM
Write-StepHeader "11" "Create New Zonal VM"

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
            -Caching $osDiskCaching
    }
    else {
        $newVmConfig = Set-AzVMOSDisk `
            -VM $newVmConfig `
            -Name $newDisks.OsDisk.Name `
            -ManagedDiskId $newDisks.OsDisk.Id `
            -CreateOption Attach `
            -Linux `
            -Caching $osDiskCaching
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
            -Caching $dataDiskCaching
    }
    
    # Add NIC
    $newVmConfig = Add-AzVMNetworkInterface -VM $newVmConfig -Id $newNic.Id -Primary
    
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

#region Step 12: List Source VM Extensions
Write-StepHeader "12" "Source VM Extensions"

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
    Write-Warning "Extensions are NOT automatically installed on the new VM."
    Write-Warning "Please manually install required extensions on '$NewVMName' using:"
    Write-Host "  Set-AzVMExtension -ResourceGroupName '$TargetResourceGroupName' -VMName '$NewVMName' ..." -ForegroundColor Gray
}
else {
    Write-Success "No extensions were installed on the source VM."
}

#endregion

#region Step 13: Cleanup Snapshots
Write-StepHeader "13" "Cleanup Snapshots"

if ($PSCmdlet.ShouldProcess("Snapshots", "Delete temporary snapshots")) {
    # Delete OS disk snapshot
    if ($snapshots.OsDisk) {
        Write-Info "Deleting OS disk snapshot '$($snapshots.OsDisk.Name)'..."
        Remove-AzSnapshot -ResourceGroupName $TargetResourceGroupName -SnapshotName $snapshots.OsDisk.Name -Force | Out-Null
        Write-Success "OS disk snapshot deleted."
    }
    
    # Delete data disk snapshots
    foreach ($dataDiskInfo in $snapshots.DataDisks) {
        Write-Info "Deleting data disk snapshot '$($dataDiskInfo.Snapshot.Name)'..."
        Remove-AzSnapshot -ResourceGroupName $TargetResourceGroupName -SnapshotName $dataDiskInfo.Snapshot.Name -Force | Out-Null
        Write-Success "Data disk snapshot deleted."
    }
}
else {
    Write-Info "[WhatIf] Would delete all temporary snapshots."
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
$newOsDiskName = $newDisks.OsDisk ? $newDisks.OsDisk.Name : $diskInfo.OsDisk.Name
$targetOsDiskSkuDisplay = $TargetOsDiskSku ? $TargetOsDiskSku : $diskInfo.OsDisk.Sku

Write-Host "New Resources Created - Zone $TargetZone :" -ForegroundColor Cyan
Write-Host "  VM:                     $NewVMName in $TargetResourceGroupName" -ForegroundColor Gray
Write-Host "  OS Disk:                $newOsDiskName ($targetOsDiskSkuDisplay)" -ForegroundColor Gray
foreach ($dd in $diskInfo.DataDisks) {
    $newDataDiskName = $dd.Name  # Same name since different RG
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
    Write-Host "  - Extensions from the source VM were NOT installed (see Step 12)" -ForegroundColor Yellow
}
Write-Host "  - Review the new VM before deleting the source resources" -ForegroundColor White
Write-Host "`n"

#endregion
