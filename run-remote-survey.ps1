<#
.SYNOPSIS
Executes a PowerShell script block on one or more remote systems using Invoke-Command.
Accumulate the output and return as structured data.

Using this initially as a simple-minded server-estate survey utility, returning a useful 
data structure which we can post-process for reports etc. e.g. for CE+.  Essentially this
saves us time and effort doing manual checks.

Longer term, this can be the basis for config management.
Retrieve actual server environment data which we could diff against
expected state and highlight changes (config 'drift')

.DESCRIPTION
This script uses the Invoke-Command cmdlet, which requires PowerShell Remoting (WinRM)
to be enabled on the target remote machine(s).

To enable WinRM on the remote systems, use this command as Administrator:
    Enable-PSRemoting -Force

.NOTES
for most machines I'll need to use my 'server account' i.e. with prefix "srv_" and a password,
because domain users don't have admin rights on servers by default.

Roger Searjeant, Circle Health Group.
#>

$ServerListPath = "serverlist.txt"
$RemoteSystems = Get-Content -Path $ServerListPath
$ReportOutputDirectory = "serverinfo"

# hardcoded list:
#$RemoteSystems = "BMI-PACS-DSE", "BMI-PACS-DSG", "CHG-PACS-PWEB1", "CHG-PACS-PWEB2"

# ScriptToRun is the script block which is run on the remote systems:
$ScriptToRun = {
    # For now, get the whole enchilada. We could filter this in future to reduce return payload,
    # if really necessary.
    $SystemInfo = Get-ComputerInfo
    
    # For some reason, the OsHotFixes property doesn't get expanded in Get-ComputerInfo output. We use
    # the following to get the hot-fixes as a separate explicit data structure
    $HotFixes = Get-ComputerInfo | Select-Object -ExpandProperty OsHotFixes | 
    Select-Object HotFixID, Description, InstalledOn | Sort-Object InstalledOn -Descending

    function testport ($hostname = 'google.com', $port = 80, $timeout = 100) {
        $requestCallback = $state = $null
        $client = New-Object System.Net.Sockets.TcpClient
        $beginConnect = $client.BeginConnect($hostname, $port, $requestCallback, $state)
        Start-Sleep -milli $timeOut
        if ($client.Connected) { $open = $true } else { $open = $false }
        $client.Close()
        [pscustomobject]@{hostname = $hostname; port = $port; open = $open }
    }

    #  $MonitoredServices = Get-Service -Name "Spooler", "wuauserv", "Schedule" -ErrorAction SilentlyContinue | Select-Object Name, Status, DisplayName

    $endpointchecks = [PSCustomObject]@{
        Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        host3     = testport "httpforever.com" 80 300
        host1     = testport "news.bbc.co.uk" 443 300
        host2     = testport "aa.net.uk" 443 300
        host4     = testport "google.co.uk" 443 300
    }

    # This should get all TCP connectons except loopbacks. Note that we resolve the process name from the PID
    # as this generally makes it easy to see what created a particular TCP connection
    $AllTcp = Get-NetTCPConnection | 
    Where-Object { $_.RemoteAddress -ne '0.0.0.0' -and 
        $_.RemoteAddress -ne '::' -and 
        $_.RemoteAddress -ne '::1' -and 
        $_.RemoteAddress -ne '127.0.0.1' -and 
        $_.RemoteAddress -ne $null } |
    select-object LocalAddress, LocalPort, RemoteAddress,   
    RemotePort, State, CreationTime, OwningProcess,
    @{Name = "ProcessName"; Expression = { (Get-Process -Id $_.OwningProcess).ProcessName } } 

    # Create separate TCP connection collections:
    # - Remote addresses are internal endpoints
    # - Everything else, i.e. external (routed) remote endpoints e.g. internet

    <#
    151.anything
    Between 154.0 and 154.16
    155.8.anything
    Between 172.16 and 172.31.anything
    10.anything

    151.anything regex is 151\..* or ^151\.
    Between 154.0 and 154.16  regex 154\.([0-9]|[1]?[0-6])\.
    155.8.anything regex is 155\.8\.*
    Between 172.16 and 172.31.anything  regex is 172\.(1[6-9]|2[0-9]|3[0-1])\.
    10.anything regex is 10\.*  
    192.168.anything regex is 192\.168\.*  

    # These queries feel very inefficient
    $InternalEndpoints = $AllTcp | Where-Object { $_.RemoteAddress -match '151\..*' -or 
                        $_.RemoteAddress -match '154\.([0-9]|[1]?[0-6])\.' -or 
                        $_.RemoteAddress -match '155\.8\.*' -or 
                        $_.RemoteAddress -match '172\.(1[6-9]|2[0-9]|3[0-1])\.' -or 
                        $_.RemoteAddress -match '192\.168\.*' }

    # There must be a better way to do this:
    $ExternalEndpoints = $AllTcp | Where-Object { $_.RemoteAddress -NotMatch '151\..*' -and 
                        $_.RemoteAddress -NotMatch '154\.([0-9]|[1]?[0-6])\.' -and 
                        $_.RemoteAddress -NotMatch '155\.8\.*' -and 
                        $_.RemoteAddress -NotMatch '172\.(1[6-9]|2[0-9]|3[0-1])\.' -and 
                        $_.RemoteAddress -NotMatch '192\.168\.*' }
    #>

    # This is better:

    $InternalEndpoints = @()
    $ExternalEndpoints = @()

    # Combine all internal address regex patterns into one pattern for efficiency, and just match
    # each entry on this.
    $InternalRegex = '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|151\.|154\.([0-9]|1[0-6])\.|155\.8\.)'

    # Make a single pass through the Tcp connection list
    foreach ($connection in $AllTcp) {
        if ($connection.RemoteAddress -match $InternalRegex) {
            $InternalEndpoints += $connection
        }
        else {
            $ExternalEndpoints += $connection
        }
    }

    # Package all collected data into a single PowerShell Custom Object.
    [PSCustomObject]@{
        Timestamp         = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        SystemDetails     = $SystemInfo
        OsHotFixes        = $HotFixes
        EndpointChecks    = $endpointchecks
        InternalEndpoints = $InternalEndpoints
        ExternalEndpoints = $ExternalEndpoints
        # MonitoredServices = $MonitoredServices
    }
}

Write-Host "--- Running commands on systems read from: $ServerListPath ---" -ForegroundColor Yellow
if (-not $RemoteSystems) {
    Write-Host "ERROR: The file '$ServerListPath' is empty or could not be found." -ForegroundColor Red
    exit
}

if (-not (Test-Path -Path $ReportOutputDirectory)) {
    Write-Host "Creating output directory: $ReportOutputDirectory" -ForegroundColor DarkYellow
    New-Item -Path $ReportOutputDirectory -ItemType Directory | Out-Null
}

foreach ($System in $RemoteSystems) {
    # Any line starting with '#' is a comment and ignored. Also ignore blank lines
    if ([String]::IsNullOrEmpty($System.Trim())) { continue }
    if ($System.SubString(0, 1) -eq '#') { continue }

    Write-Host "`n--- Processing System: $System ---" -ForegroundColor Cyan

    $CsvOutputPath = Join-Path -Path $ReportOutputDirectory -ChildPath "$($System)-SystemReport-$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
    $JsonOutputPath = Join-Path -Path $ReportOutputDirectory -ChildPath "$($System)-SystemReport-$(Get-Date -Format 'yyyyMMdd_HHmm').json"

    try {
        # Must use ErrorAction Stop to ensure that any error is caught by the catch block
        $Results = Invoke-Command -ComputerName $System -ScriptBlock $ScriptToRun  -ErrorAction Stop

        # Annoying that you have to specify a depth - the default is only 2!
        # When this is working we could use -Compress to remove redundant whitespace
        # but this doesn't save very much
        $Results | 
        ConvertTo-Json -Depth 8 | 
        Set-Content -Path $JsonOutputPath -Encoding UTF8
    }
    catch {
        # write the exception message to the console and also to a JSON file so we have a record of the failure
        write-Host "`n--- ERROR EXECUTING COMMAND ---" -ForegroundColor Red
        write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
        [PSCustomObject]@{
            Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            Error     = $true
            Message   = $_.Exception.Message
        } |
        ConvertTo-Json -Depth 5 | 
        Set-Content -Path $JsonOutputPath -Encoding UTF8

        # Write-Host "`n--- ERROR EXECUTING COMMAND ---" -ForegroundColor Red
        # Write-Host "Error details: $($_.Exception.Message)" -ForegroundColor Red
        # Write-Host "Possible causes: WinRM not enabled, firewall blocking access, or incorrect computer name/credentials." -ForegroundColor Red
    }

}
