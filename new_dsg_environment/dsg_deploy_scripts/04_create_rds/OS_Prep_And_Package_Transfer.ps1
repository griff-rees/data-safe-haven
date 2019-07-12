param(
  [Parameter(Position=0, Mandatory = $true, HelpMessage = "Enter DSG ID (usually a number e.g enter '9' for DSG9)")]
  [string]$dsgId
)

Import-Module Az
Import-Module $PSScriptRoot/../GeneratePassword.psm1 -Force
Import-Module $PSScriptRoot/../DsgConfig.psm1 -Force
Import-Module $PSScriptRoot/../GenerateSasToken.psm1 -Force

# Get DSG config
$config = Get-DsgConfig($dsgId)

# Temporarily switch to DSG subscription to run remote scripts
$prevContext = Get-AzContext
$_ = Set-AzContext -SubscriptionId $config.dsg.subscriptionName

$rdsResourceGroup = $config.dsg.rds.rg;
$helperScriptDir = Join-Path $PSScriptRoot "helper_scripts" "Configure_RDS_Servers";

# Move RDS VMs into correct OUs
$vmOuMoveParams = @{
    dsgDn = "`"$($config.dsg.domain.dn)`""
    dsgNetbiosName = "`"$($config.dsg.domain.netbiosName)`""
    gatewayHostname = "`"$($config.dsg.rds.gateway.hostname)`""
    sh1Hostname = "`"$($config.dsg.rds.sessionHost1.hostname)`""
    sh2Hostname = "`"$($config.dsg.rds.sessionHost2.hostname)`""
};

$scriptPath = Join-Path $helperScriptDir "remote_scripts" "Move_RDS_VMs_Into_OUs.ps1"
Write-Host " - Moving RDS VMs to correct OUs on DSG DC"
Invoke-AzVMRunCommand -ResourceGroupName $($config.dsg.dc.rg) `
    -Name "$($config.dsg.dc.vmName)" `
    -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath `
    -Parameter $vmOuMoveParams

# Run OS prep on all RDS VMs
$osPrepParams = @{
    dsgFqdn = "`"$($config.dsg.domain.fqdn)`""
    shmFqdn = "`"$($config.shm.domain.fqdn))`""
};

$scriptPath = Join-Path $helperScriptDir "remote_scripts" "OS_Prep_Remote.ps1"
Write-Host " - Running OS Prep on RDS Gateway"
Invoke-AzVMRunCommand -ResourceGroupName $rdsResourceGroup `
    -Name "$($config.dsg.rds.gateway.vmName)" `
    -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath `
    -Parameter $osPrepParams

Write-Host " - Running OS Prep on RDS Session Host 1"
Invoke-AzVMRunCommand -ResourceGroupName $rdsResourceGroup `
    -Name "$($config.dsg.rds.sessionHost1.vmName)" `
    -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath `
    -Parameter $osPrepParams

Write-Host " - Running OS Prep on RDS Session Host 2"
Invoke-AzVMRunCommand -ResourceGroupName $rdsResourceGroup `
    -Name "$($config.dsg.rds.sessionHost2.vmName)" `
    -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath `
    -Parameter $osPrepParams

# Transfer files
# Temporarily switch to storage account subscription
$storageAccountSubscription = $config.shm.subscriptionName
$_ = Set-AzContext -SubscriptionId $storageAccountSubscription;
$storageAccountRg = $config.shm.storage.artifacts.rg
$storageAccountName = $config.shm.storage.artifacts.accountName
$shareName = "configpackages"
$packageFolder = "packages"

# Get software package file paths
$storageAccount = Get-AzStorageAccount -Name $storageAccountName -ResourceGroupName $storageAccountRg

$files = Get-AzStorageFile -ShareName $shareName -path $packageFolder -Context $storageAccount.Context | Get-AzStorageFile
$filePaths = $files | ForEach-Object{"$packageFolder\$($_.Name)"}

$pipeSeparatedFilePaths = $filePaths -join "|"

$sasToken = New-ReadOnlyAccountSasToken -subscriptionName $storageAccountSubscription `
                -resourceGroup $storageAccountRg -accountName $storageAccountName

# Temporarily switch to DSG subscription to run remote scripts
$_ = Set-AzContext -SubscriptionId $config.dsg.subscriptionName

# Download software packages to RDS Session Hosts
$packageDownloadParams = @{
    storageAccountName = "`"$storageAccountName`""
    storageService = "file"
    shareOrContainerName = "`"$shareName`""
    sasToken = "`"$sasToken`""
    pipeSeparatedremoteFilePaths = "`"$pipeSeparatedFilePaths`""
    downloadDir = "C:\Software"
}
$packageDownloadParams

$scriptPath = Join-Path $helperScriptDir "remote_scripts" "Download_Files.ps1"
Write-Host " - Copying packages to RDS Session Host 1"
Invoke-AzVMRunCommand -ResourceGroupName $rdsResourceGroup `
    -Name "$($config.dsg.rds.sessionHost1.vmName)" `
    -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath `
    -Parameter $packageDownloadParams

Write-Host " - Copying packages to RDS Session Host 2"
Invoke-AzVMRunCommand -ResourceGroupName $rdsResourceGroup `
    -Name "$($config.dsg.rds.sessionHost2.vmName)" `
    -CommandId 'RunPowerShellScript' -ScriptPath $scriptPath `
    -Parameter $packageDownloadParams


# Upload RDS deployment scripts to RDS Gateway
$scriptPath = Join-Path $helperScriptDir "local_scripts" "Upload_RDS_Deployment_Scripts.ps1"
Write-Host " - Uploading RDS environment installation scripts"
Invoke-Expression -Command "$scriptPath -dsgId $dsgId"

# Create NPS shared secret if it doesn't exist
# Fetch admin password (or create if not present)
$npsSecret = (Get-AzKeyVaultSecret -vaultName $config.dsg.keyVault.name -name $config.dsg.rds.gateway.npsSecretName).SecretValueText;
if ($null -eq $npsSecret) {
  Write-Host " - Creating NPS shared secret for RDS gateway"
  # Create password locally but round trip via KeyVault to ensure it is successfully stored
  $newPassword = New-Password;
  $newPassword = (ConvertTo-SecureString $newPassword -AsPlainText -Force);
  Set-AzKeyVaultSecret -VaultName $config.dsg.keyVault.name -Name $config.dsg.rds.gateway.npsSecretName -SecretValue $newPassword;
  $npsSecret = (Get-AzKeyVaultSecret -VaultName $config.dsg.keyVault.name -Name $config.dsg.rds.gateway.npsSecretName).SecretValueText;
} else {
    Write-Host " -  NPS shared secret for RDS gateway already exists"
}

# Switch back to original subscription
$_ = Set-AzContext -Context $prevContext;
