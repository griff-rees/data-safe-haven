# You will need `Install-Package Communary.PASM`
param(
    [Parameter(Mandatory = $true, HelpMessage = "Name of the test (proposed) subscription")]
    [string]$Subscription,
    [Parameter(ParameterSetName="BenchmarkSubscription", Mandatory = $true, HelpMessage = "Name of the benchmark subscription to compare against")]
    [string]$BenchmarkSubscription,
    [Parameter(ParameterSetName="BenchmarkConfig", Mandatory = $true, HelpMessage = "Path to the benchmark config to compare against")]
    [string]$BenchmarkConfig,
    [Parameter(Mandatory = $false, HelpMessage = "Print verbose logging messages")]
    [switch]$VerboseLogging = $false
)

Import-Module Az
Import-Module Communary.PASM
Import-Module $PSScriptRoot/../common_powershell/Logging.psm1 -Force

function Select-ClosestMatch {
    param (
        [Parameter(Position = 0)][ValidateNotNullOrEmpty()]
        [string] $Value,
        [Parameter(Position = 1)][ValidateNotNullOrEmpty()]
        [System.Array] $Array
    )
    $Array | Sort-Object @{Expression={ Get-PasmScore -String1 $Value -String2 $_ -Algorithm "LevenshteinDistance" }; Ascending=$false} | Select-Object -First 1
}


function Compare-NSGRules {
    param (
        [Parameter()]
        [System.Array] $BenchmarkRules,
        [Parameter()]
        [System.Array] $TestRules
    )
    $nMatched = 0
    $unmatched = @()
    foreach ($benchmarkRule in $BenchmarkRules) {
        $lowestDifference = 99
        $closestMatchingRule = $null
        foreach ($testRule in $TestRules) {
            $difference = 0
            if ($benchmarkRule.Protocol -ne $testRule.Protocol) { $difference += 1 }
            if ([string]($benchmarkRule.SourcePortRange) -ne [string]($testRule.SourcePortRange)) { $difference += 1 }
            if ([string]($benchmarkRule.DestinationPortRange) -ne [string]($testRule.DestinationPortRange)) { $difference += 1 }
            if ([string]($benchmarkRule.SourceAddressPrefix) -ne [string]($testRule.SourceAddressPrefix)) { $difference += 1 }
            if ([string]($benchmarkRule.DestinationAddressPrefix) -ne [string]($testRule.DestinationAddressPrefix)) { $difference += 1 }
            if ($benchmarkRule.Access -ne $testRule.Access) { $difference += 1 }
            if ($benchmarkRule.Priority -ne $testRule.Priority) { $difference += 1 }
            if ($benchmarkRule.Direction -ne $testRule.Direction) { $difference += 1 }
            if ($difference -lt $lowestDifference) {
                $lowestDifference = $difference
                $closestMatchingRule = $testRule
            }
            if ($difference -eq 0) { break }
        }

        if ($lowestDifference -eq 0) {
            $nMatched += 1
            if ($VerboseLogging) { Add-LogMessage -Level Info "Found matching rule for $($benchmarkRule.Name)" }
        } else {
            Add-LogMessage -Level Error "Could not find matching rule for $($benchmarkRule.Name)"
            $unmatched += $benchmarkRule.Name
            $benchmarkRule | Out-String
            Add-LogMessage -Level Info "Closest match was:"
            $closestMatchingRule | Out-String
        }
    }

    $nTotal = $nMatched + $unmatched.Count
    if ($nMatched -eq $nTotal) {
        Add-LogMessage -Level Success "Matched $nMatched/$nTotal rules"
    } else {
        Add-LogMessage -Level Failure "Matched $nMatched/$nTotal rules"
    }
}


function Test-OutboundConnection {
    param (
        [Parameter(Position = 0)][ValidateNotNullOrEmpty()]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine] $VM,
        [Parameter(Position = 0)][ValidateNotNullOrEmpty()]
        [string] $DestinationAddress,
        [Parameter(Position = 1)][ValidateNotNullOrEmpty()]
        [string] $DestinationPort
    )
    # Get the network watcher, creating a new one if required
    $networkWatcher = Get-AzNetworkWatcher | Where-Object -Property Location -EQ -Value $VM.Location
    if (-Not $networkWatcher) {
        $networkWatcher = New-AzNetworkWatcher -Name "NetworkWatcher" -ResourceGroupName "NetworkWatcherRG" -Location $VM.Location
    }
    # Ensure that the VM has the extension installed (if we have permissions for this)
    $networkWatcherExtension = Get-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name | Where-Object { ($_.Publisher -eq "Microsoft.Azure.NetworkWatcher") -and ($_.ProvisioningState -eq "Succeeded") }
    if (-Not $networkWatcherExtension) {
        Add-LogMessage -Level Info "... registering the Azure NetworkWatcher extension on $($VM.Name). "
        # Add the Windows extension
        if ($VM.OSProfile.WindowsConfiguration) {
            $_ = Set-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Location $VM.Location -Name "AzureNetworkWatcherExtension" -Publisher "Microsoft.Azure.NetworkWatcher" -Type "NetworkWatcherAgentWindows" -TypeHandlerVersion "1.4" -ErrorVariable NotInstalled -ErrorAction SilentlyContinue
            if ($NotInstalled) {
                Add-LogMessage -Level Warning "Unable to register Windows network watcher extension for $($VM.Name)"
                return "Unknown"
            }
        }
        # Add the Linux extension
        if ($VM.OSProfile.LinuxConfiguration) {
            $_ = Set-AzVMExtension -ResourceGroupName $VM.ResourceGroupName -VMName $VM.Name -Location $VM.Location -Name "AzureNetworkWatcherExtension" -Publisher "Microsoft.Azure.NetworkWatcher" -Type "NetworkWatcherAgentLinux" -TypeHandlerVersion "1.4" -ErrorVariable NotInstalled -ErrorAction SilentlyContinue
            if ($NotInstalled) {
                Add-LogMessage -Level Warning "Unable to register Linux network watcher extension for $($VM.Name)"
                return "Unknown"
            }
        }
    }
    Add-LogMessage -Level Info "... testing connectivity"
    $networkCheck = Test-AzNetworkWatcherConnectivity -NetworkWatcher $networkWatcher -SourceId $VM.Id -DestinationAddress $DestinationAddress -DestinationPort $DestinationPort -ErrorVariable NotAvailable -ErrorAction SilentlyContinue
    if ($NotAvailable) {
        Add-LogMessage -Level Warning "Unable to test connection for $($VM.Name)"
        return "Unknown"
    } else {
        return $networkCheck.ConnectionStatus
    }
}

function Convert-RuleToEffectiveRule {
    param (
        [Parameter(Position = 0)][ValidateNotNullOrEmpty()]
        [System.Object] $rule
    )
    $effectiveRule = [Microsoft.Azure.Commands.Network.Models.PSEffectiveSecurityRule]::new()
    $effectiveRule.Name = $rule.Name
    $effectiveRule.Protocol = $rule.Protocol.Replace("*", "All")
    # Source port range
    $effectiveRule.SourcePortRange = New-Object System.Collections.Generic.List[string]
    foreach ($port in $rule.SourcePortRange) {
        if ($port -eq "*") { $effectiveRule.SourcePortRange.Add("0-65535"); break }
        elseif ($port.Contains("-")) { $effectiveRule.SourcePortRange.Add($port) }
        else { $effectiveRule.SourcePortRange.Add("$port-$port") }
    }
    # Destination port range
    $effectiveRule.DestinationPortRange = New-Object System.Collections.Generic.List[string]
    foreach ($port in $rule.DestinationPortRange) {
        if ($port -eq "*") { $effectiveRule.DestinationPortRange.Add("0-65535"); break }
        elseif ($port.Contains("-")) { $effectiveRule.DestinationPortRange.Add($port) }
        else { $effectiveRule.DestinationPortRange.Add("$port-$port") }
    }
    # Source address prefix
    $effectiveRule.SourceAddressPrefix = New-Object System.Collections.Generic.List[string]
    foreach ($prefix in $rule.SourceAddressPrefix) {
        if ($prefix -eq "0.0.0.0/0") { $effectiveRule.SourceAddressPrefix.Add("*"); break }
        else { $effectiveRule.SourceAddressPrefix.Add($rule.SourceAddressPrefix) }
    }
    # Destination address prefix
    $effectiveRule.DestinationAddressPrefix = New-Object System.Collections.Generic.List[string]
    foreach ($prefix in $rule.DestinationAddressPrefix) {
        if ($prefix -eq "0.0.0.0/0") { $effectiveRule.DestinationAddressPrefix.Add("*"); break }
        else { $effectiveRule.DestinationAddressPrefix.Add($rule.DestinationAddressPrefix) }
    }
    $effectiveRule.Access = $rule.Access
    $effectiveRule.Priority = $rule.Priority
    $effectiveRule.Direction = $rule.Direction
    return $effectiveRule
}


function Get-NSGRules {
    param (
        [Parameter(Position = 0)][ValidateNotNullOrEmpty()]
        [Microsoft.Azure.Commands.Compute.Models.PSVirtualMachine] $VM
    )
    $effectiveNSG = Get-AzEffectiveNetworkSecurityGroup -NetworkInterfaceName ($VM.NetworkProfile.NetworkInterfaces.Id -Split '/')[-1] -ResourceGroupName $VM.ResourceGroupName -ErrorVariable NotAvailable -ErrorAction SilentlyContinue
    if ($NotAvailable) {
        # Not able to get effective rules so we'll construct them by hand
        $rules = @()
        # Get rules from NSG directly attached to the NIC
        $nic = Get-AzNetworkInterface | Where-Object { $_.Id -eq $VM.NetworkProfile.NetworkInterfaces.Id }
        $directNsgs = Get-AzNetworkSecurityGroup | Where-Object { $_.Id -eq $nic.NetworkSecurityGroup.Id }
        foreach ($directNsg in $directNsgs) {
            $rules = $rules + $directNsg.SecurityRules + $directNsg.DefaultSecurityRules
        }
        # Get rules from NSG attached to the subnet
        $subnetNsgs = Get-AzNetworkSecurityGroup | Where-Object { $_.Subnets.Id -eq $nic.IpConfigurations.Subnet.Id }
        foreach ($subnetNsg in $subnetNsgs) {
            $rules = $rules + $subnetNsg.SecurityRules + $subnetNsg.DefaultSecurityRules
        }
        $effectiveRules = @()
        # Convert each PSSecurityRule into a PSEffectiveSecurityRule
        foreach ($rule in $rules) {
            $effectiveRules = $effectiveRules + $(Convert-RuleToEffectiveRule $rule) #$effectiveRule
        }
        return $effectiveRules
    } else {
        $effectiveRules = $effectiveNSG.EffectiveSecurityRules
        foreach ($effectiveRule in $effectiveRules) {
            if ($effectiveRule.SourceAddressPrefix[0] -eq "0.0.0.0/0") { $effectiveRule.SourceAddressPrefix.Clear(); $effectiveRule.SourceAddressPrefix.Add("*") }
            if ($effectiveRule.DestinationAddressPrefix[0] -eq "0.0.0.0/0") { $effectiveRule.DestinationAddressPrefix.Clear(); $effectiveRule.DestinationAddressPrefix.Add("*") }
        }
        return $effectiveRules
    }
}


# Get original context before switching subscription
# --------------------------------------------------
$originalContext = Get-AzContext


# Load configuration from a benchmark subscription or config
# ----------------------------------------------------------
if ($BenchmarkSubscription) {
    $JsonConfig = [ordered]@{}
    # Get VMs in current subscription
    $_ = Set-AzContext -SubscriptionId $BenchmarkSubscription
    $benchmarkVMs = Get-AzVM | Where-Object { $_.Name -NotLike "*shm-deploy*" }
    Add-LogMessage -Level Info "Found $($benchmarkVMs.Count) VMs in subscription: '$BenchmarkSubscription'"
    foreach ($VM in $benchmarkVMs) {
        Add-LogMessage -Level Info "... $($VM.Name)"
    }
    # Get the NSG rules and connectivity for each VM in the subscription
    foreach ($benchmarkVM in $benchmarkVMs) {
        Add-LogMessage -Level Info "Getting NSG rules and connectivity for $($VM.Name)"
        $DestinationPort = 80
        if ($VM.Name.Contains("MIRROR")) { $DestinationPort = 443 }
        $JsonConfig[$benchmarkVM.Name] = [ordered]@{
            Internet = Test-OutboundConnection -VM $benchmarkVM -DestinationAddress "google.com" -DestinationPort 80
            Rules = Get-NSGRules -VM $benchmarkVM
        }
    }
    $OutputFile = New-TemporaryFile
    Out-File -FilePath $OutputFile -Encoding "UTF8" -InputObject ($JsonConfig | ConvertTo-Json -Depth 10)
    Add-LogMessage -Level Info "Configuration file generated at '$($OutputFile.FullName)'"
} elseif ($BenchmarkConfig) {
    $JsonConfig = Get-Content -Path $BenchmarkConfig -Raw -Encoding UTF-8 | ConvertFrom-Json
}


# Deserialise VMs from JSON config
# --------------------------------
$benchmarkVMs = @()
foreach ($JsonVm in $JsonConfig.PSObject.Properties) {
    $VM = New-Object -TypeName PsObject
    $VM | Add-Member -MemberType NoteProperty -Name Name -Value $JsonVm.Name
    $VM | Add-Member -MemberType NoteProperty -Name Internet -Value $JsonVm.PSObject.Properties.Value.Internet
    $VM | Add-Member -MemberType NoteProperty -Name Rules -Value @()
    foreach ($rule in $JsonVm.PSObject.Properties.Value.Rules) {
        if ($rule.Name) { $VM.Rules += $(Convert-RuleToEffectiveRule $rule) }
    }
    $benchmarkVMs += $VM
}


# Get VMs in test SHM
# -------------------
$_ = Set-AzContext -SubscriptionId $Subscription
$testVMs = Get-AzVM
Add-LogMessage -Level Info "Found $($testVMs.Count) VMs in subscription: '$Subscription'"
foreach ($VM in $testVMs) {
    Add-LogMessage -Level Info "... $($VM.Name)"
}


# Create a hash table which maps current SHM VMs to new ones
# ----------------------------------------------------------
$vmHashTable = @{}
foreach ($benchmarkVM in $benchmarkVMs) {
    $nameToCheck = $benchmarkVM.Name
    # Override matches for names that would otherwise fail
    if ($nameToCheck.StartsWith("CRAN-MIRROR")) { $nameToCheck = $nameToCheck.Replace("MIRROR", "") }
    if ($nameToCheck.StartsWith("PYPI-MIRROR")) { $nameToCheck = $nameToCheck.Replace("MIRROR", "") }
    if ($nameToCheck.StartsWith("RDSSH1")) { $nameToCheck = $nameToCheck.Replace("RDSSH1", "APP-SRE") }
    if ($nameToCheck.StartsWith("RDSSH2")) { $nameToCheck = $nameToCheck.Replace("RDSSH2", "DKP-SRE") }
    # Only match against names that have not been matched yet
    $testVMNames = $testVMs | ForEach-Object { $_.Name } | Where-Object { ($vmHashTable.Values | ForEach-Object { $_.Name }) -NotContains $_ }
    $testVM = $testVMs | Where-Object { $_.Name -eq $(Select-ClosestMatch -Array $testVMNames -Value $nameToCheck) }
    $vmHashTable[$benchmarkVM] = $testVM
    Add-LogMessage -Level Info "matched $($testVM.Name) => $($benchmarkVM.Name)"
}


# Iterate over paired VMs checking their network settings
# -------------------------------------------------------
foreach ($benchmarkVM in $benchmarkVMs) {
    $testVM = $vmHashTable[$benchmarkVM]

    # Get parameters for new VM
    # -------------------------
    $_ = Set-AzContext -SubscriptionId $Subscription
    Add-LogMessage -Level Info "Getting NSG rules and connectivity for $($testVM.Name)"
    $testRules = Get-NSGRules -VM $testVM
    # Set appropriate port for testing internet access
    $DestinationPort = 80
    if ($testVM.Name.Contains("MIRROR")) { $DestinationPort = 443 }
    $testInternet = Test-OutboundConnection -VM $testVM -DestinationAddress "google.com" -DestinationPort $DestinationPort
    # Check that each NSG rule has a matching equivalent (which might be named differently)
    Add-LogMessage -Level Info "Comparing NSG rules for $($benchmarkVM.Name) and $($testVM.Name)"
    Add-LogMessage -Level Info "... ensuring that all $($benchmarkVM.Name) rules exist on $($testVM.Name)"
    Compare-NSGRules -BenchmarkRules $benchmarkVM.Rules -TestRules $testRules
    Add-LogMessage -Level Info "... ensuring that all $($testVM.Name) rules exist on $($benchmarkVM.Name)"
    Compare-NSGRules -BenchmarkRules $testRules -TestRules $benchmarkVM.Rules

    # Check that internet connectivity is the same for matched VMs
    Add-LogMessage -Level Info "Comparing internet connectivity for $($benchmarkVM.Name) and $($testVM.Name)..."
    if ($benchmarkVM.Internet -eq $testInternet) {
        Add-LogMessage -Level Success "The internet is '$($benchmarkVM.Internet)' from both"
    } else {
        Add-LogMessage -Level Failure "The internet is '$($benchmarkVM.Internet)' from $($benchmarkVM.Name)"
        Add-LogMessage -Level Failure "The internet is '$($testInternet)' from $($testVM.Name)"
    }
}


# Switch back to original subscription
# ------------------------------------
$_ = Set-AzContext -Context $originalContext
