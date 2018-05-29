# Downloads the Visual Studio Online Build Agent, installs on the new machine, registers with the Visual
# Studio Online account, and adds to the specified build agent pool
[CmdletBinding()]
param(
    [string] $VstsAccount,
	[string] $resourceGroupName,
	[string] $storageAccountName,
    [string] $VaultName,
	[string] $SecretName,
    [string] $PoolName,
	[string] $workingDirectory
	
)

###################################################################################################
#
# PowerShell configurations
#

# NOTE: Because the $ErrorActionPreference is "Stop", this script will stop on first failure.
#       This is necessary to ensure we capture errors inside the try-catch-finally block.
$ErrorActionPreference = "Stop"

# Configure strict debugging.
Set-PSDebug -Strict

###################################################################################################

function Handle-LastError
{
    $message = $error[0].Exception.Message
    if ($message)
    {
        Write-Host -Object "ERROR: $message" -ForegroundColor Red
    }
    
    # IMPORTANT NOTE: Throwing a terminating error (using $ErrorActionPreference = "Stop") still
    # returns exit code zero from the PowerShell script when using -File. The workaround is to
    # NOT use -File when calling this script and leverage the try-catch-finally block and return
    # a non-zero exit code from the catch block.
    exit -1
}

###########################################################################################################
#
#
# Copy the agent from the Storage blob on to the VM and extract it to a folder.
#
#
############################################################################################################

function Copy-Blobs
{
	Param(
		[parameter(Mandatory)]
			[string] $storage_account,
		[parameter(Mandatory)]
			[string] $resourceGroupName,
		[Parameter(Mandatory)]
			[string] $outputRootFolder		
	)

	$container = "vsts-agent"
	$zipFileName = "vsts-agent-win7-x64-2.124.0.zip"

	 Write-Host "$(get-date) *** Copy-Blobs from storage '$container to '$outputRootFolder'"
	 # Create output root directly if it does not exist
    if(-NOT (Test-Path $outputRootFolder -PathType Container))
    {
        $rootFoler = New-Item $outputRootFolder -ItemType directory
    }
	cd $outputRootFolder
	$agentInstallDir = Get-Location

    [string] $agentInstallPath = $null
    $agentUrl = "https://$storage_account.blob.core.windows.net/$container/$zipFileName"
    $agentDir =   Join-Path -Path $agentInstallDir -ChildPath "VSTSInstaller"
	$zipFilePath = Join-Path -Path $agentInstallDir -ChildPath "vstsagent.zip"
    New-Item -ItemType Directory -Force -Path $agentDir | Out-Null
    # Construct the agent folder under the specified drive.    
    try
    {
        # Create the directory for this agent.
        Write-Host "Invoke-WebRequest to download the vstsAgent"
        Invoke-WebRequest $agentUrl -OutFile $zipFilePath -UseBasicParsing
 	    Write-Host "Extracting the build files to $agentDir"		
        Add-Type -AssemblyName System.IO.Compression.FileSystem ; [System.IO.Compression.ZipFile]::ExtractToDirectory($zipFilePath, $agentDir)
    }
    catch
    {
        $agentDir = $null
        Write-Error "Failed to create the agent directory at $installPathDir."
    }    
    return $agentDir	
}
###########################################################################################################
#
#
# Get the path to the Config.cmd file one the Agent files are copied to the VM
#
#
############################################################################################################
function Get-AgentInstaller
{
    param(
        [string] $InstallPath
    )
    Write-Host $InstallPath
    pushd -path $InstallPath
    $agentExePath = [System.IO.Path]::Combine($InstallPath, 'config.cmd')

    if (![System.IO.File]::Exists($agentExePath))
    {
        Write-Error "Agent installer file not found: $agentExePath"
    }
    
    return $agentExePath
}

###########################################################################################################
#
#
# Install the VSTS Agent in the Build Agent and add it to the Agent pool
#
#
############################################################################################################
function Install-Agent
{
    param(
        $Config
    )

    try
    {
        Write-Host 'Set the current directory to the agent dedicated one previously created.'
        # Set the current directory to the agent dedicated one previously created.
        pushd -Path $Config.AgentInstallPath

        Write-Host 'Create a parameter for the Config.cmd'
        # The actual install of the agent. Using --runasservice, and some other values that could be turned into paramenters if needed.
        $agentConfigArgs = "--unattended", "--url", $Config.ServerUrl, "--auth", "PAT","--token", $Config.VstsUserPassword, "--pool", $Config.PoolName, "--runasservice"        
        .\config.cmd --unattended --url $Config.ServerUrl --auth PAT --token $Config.VSTSUserPassword --pool $Config.PoolName --runasservice
    }
    finally
    {
        popd
    }
}

###########################################################################################################
#
#
# Install the VSTS Agent in the Build Agent and add it to the Agent pool
#
#
############################################################################################################
function Resize-Disk
{
	New-NetFirewallRule -DisplayName VulnScanContainer -Direction Inbound -Protocol TCP -LocalPort 445,135,139,49152,49153,49154,49155,49156,12005 -Action Allow
	$MaxSize = (Get-PartitionSupportedSize -DriveLetter c).SizeMax;
	if((Get-Partition -DriveLetter c).Size -ne $MaxSize)
	{
		'Resize Drive C'| tee -append powershell.log;
		Resize-Partition -DriveLetter c -Size $MaxSize
	}
	else
	{
		'C volume is already at max size'| tee -append powershell.log
	};
	'Done'| tee -append powershell.log
}
###################################################################################################

#
# Handle all errors in this script.
#

trap
{
    # NOTE: This trap will handle all errors. There should be no need to use a catch below in this
    #       script, unless you want to ignore a specific error.
    Handle-LastError
}

###################################################################################################

#
# Main execution block.
#
###################################################################################################
try
{
	Write-Host "Resize the partition to fit the needs."
	Resize-Disk
	$apiversion = "?api-version=2016-10-01"
	$secretUri = "https://$VaultName.vault.azure.net/secrets/$SecretName$apiversion"
	$outputRootFolder = "$workingDirectory\Resources"
	$container = "vsts-agent"
	$windowsLogonAccount= "NT AUTHORITY\NETWORK SERVICE"    
    $workDirectory = "_work" 
    $agentInstallPath = "$outputRootFolder\VSTSInstaller"

	Write-Host "Retreive the VSTSPassword from the KeyVault"
	$response = Invoke-WebRequest -Uri http://localhost:50342/oauth2/token -Method GET -Body @{resource="https://vault.azure.net"} -Headers @{Metadata="true"} -UseBasicParsing
	$content = $response.Content | ConvertFrom-Json 
	$KeyVaultToken = $content.access_token
	$response = (Invoke-WebRequest -Uri $secretUri -Method GET -Headers @{Authorization="Bearer $KeyVaultToken"} -UseBasicParsing).content | ConvertFrom-Json
	$VstsUserPassword = $response.value

    Write-Host 'Preparing agent installation location'
    $agentDir = Copy-Blobs -storage_account  $storageAccountName -resourceGroupName $resourceGroupName -outputRootFolder $outputRootFolder 

    Write-Host 'Getting agent installer path'
    $agentExePath = Get-AgentInstaller -InstallPath $agentInstallPath
   
    # Call the agent with the configure command and all the options (this creates the settings file)
    # without prompting the user or blocking the cmd execution.
    Write-Host 'Installing agent'
    $config = @{
       AgentExePath = $agentExePath 
	   AgentInstallPath = $agentInstallPath
       PoolName = $PoolName
       ServerUrl = "https://$VstsAccount.visualstudio.com"
       VstsUserPassword = $VstsUserPassword 
       WindowsLogonAccount = $windowsLogonAccount 
       WorkDirectory = $workDirectory     
    }
    Install-Agent -Config $config
    
    Write-Host 'Done'
}
finally
{
    popd
}