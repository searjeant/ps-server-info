<#
.SYNOPSIS

Server check script to be run on a single host, creates an output file containing
config and network data for the host, in the same directory as the script.

.DESCRIPTION

A simple-minded server survey utility, returning a useful 
data structure which we can post-process for reports etc. e.g. for CE+. 

.NOTES

Author: Roger Searjeant, Circle Health Group.

Trying to keep this as simple as possible, so no external dependencies. Also trying
to follow good practice with comments, help etc.
We can tweak timeouts, but I think 300ms is a reasonable default. If there is no
response in 0.3 of a second, then something is probably wrong anyway.
#>

$systemname = [System.Environment]::MachineName
$SystemInfo = Get-ComputerInfo

# For some reason, the OsHotFixes property doesn't always get expanded in Get-ComputerInfo output. So
# use the following to get the hot-fixes as a separate explicit data structure:
$HotFixes = Get-ComputerInfo | Select-Object -ExpandProperty OsHotFixes | 
Select-Object HotFixID, Description, InstalledOn | Sort-Object InstalledOn -Descending

<# 
.SYNOPSIS
    Attempt to connect to the HTTP endpoint in the url parameter, returning the status code,
    or the exception status code if the connection fails.
.DESCRIPTION
    See synopsis!
.PARAMETER url
    The URL to test. Default is http://www.google.co.uk
.PARAMETER timeout
    The timeout in milliseconds. Default is 300ms. 
.EXAMPLE
    TestHttpEndpoint -url 'http://www.google.co.uk' -timeout 300 
    Tests the specified URL with a timeout of 300ms.
    Could use Invoke-WebRequest, but this is a bit more lightweight.
.NOTES
#>
function TestHttpEndpoint ($url = 'http://www.google.co.uk', $timeout = 300) {
    $request = [System.Net.WebRequest]::Create($url)
    $request.Timeout = $timeout
    try {
        $response = $request.GetResponse()
        $status = $response.StatusCode.value__
        $response.Close()
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
    }
    [pscustomobject]@{url = $url; status = $status }
}

<#
.SYNOPSIS
    Test whether a TCP connection can be opened to the specified hostname and port.
.DESCRIPTION
    Uses System.Net.Sockets.TcpClient to attempt a TCP connection to the specified hostname and port,
    returning a simple object with the hostname, port and whether the connection was successful.
.PARAMETER hostname
    The hostname to test. Default is google.com 
.PARAMETER port
    The TCP port to test. Default is 80.   
#>
function TestTcpEndpoint ($hostname = 'google.com', $port = 80, $timeout = 100) {
    $requestCallback = $state = $null
    $client = New-Object System.Net.Sockets.TcpClient
    $null = $client.BeginConnect($hostname, $port, $requestCallback, $state)
    Start-Sleep -milli $timeOut
    if ($client.Connected) { $open = $true } else { $open = $false }
    $client.Close()
    [pscustomobject]@{hostname = $hostname; port = $port; open = $open }
}

#  $MonitoredServices = Get-Service -Name "Spooler", "wuauserv", "Schedule" -ErrorAction SilentlyContinue | Select-Object Name, Status, DisplayName

$httpChecks = [PSCustomObject]@{
    Timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    google    = TestHttpEndpoint -url 'http://www.google.co.uk'  # Note port80 implied
    bbc       = TestHttpEndpoint -url 'https://news.bbc.co.uk' 
    thetimes  = TestHttpEndpoint -url 'https://www.thetimes.com/' 
    nhs       = TestHttpEndpoint -url 'https://www.nhs.uk' 
    chg       = TestHttpEndpoint -url 'https://www.circlehealthgroup.co.uk'
}

$tcpChecks = [PSCustomObject]@{
    Timestamp       = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    httpforever     = TestTcpEndpoint "httpforever.com" 80 300
    bbc             = TestTcpEndpoint "news.bbc.co.uk" 443 300
    nhs             = TestTcpEndpoint "www.nhs.uk" 443 300
    google          = TestTcpEndpoint "google.co.uk" 443 300
    tcpbinOddPort   = TestTcpEndpoint "tcpbin.com" 4242 300   # Try an odd port. Expecting 'false'
    tcpbinHttpsPort = TestTcpEndpoint "tcpbin.com" 443 300 
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

$InternalEndpoints = @()
$ExternalEndpoints = @()

# Combine all internal address regex patterns into one pattern for efficiency, and just match
# each entry on this.
$InternalRegex = '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|151\.|154\.([0-9]|1[0-6])\.|155\.8\.)'

foreach ($connection in $AllTcp) {
    if ($connection.RemoteAddress -match $InternalRegex) {
        $InternalEndpoints += $connection
    }
    else {
        $ExternalEndpoints += $connection
    }
}

$alldata = [PSCustomObject]@{
    SystemName        = $([System.Environment]::MachineName)
    Timestamp         = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    SystemDetails     = $SystemInfo
    OsHotFixes        = $HotFixes
    HttpChecks        = $httpChecks
    TcpChecks         = $tcpChecks
    InternalEndpoints = $InternalEndpoints
    ExternalEndpoints = $ExternalEndpoints
    # MonitoredServices = $MonitoredServices
}

$JsonOutputPath = "$($systemname)-SystemReport-$(Get-Date -Format 'yyyyMMdd_HHmm').json"
$alldata | ConvertTo-Json -Depth 8 | Set-Content -Path $JsonOutputPath -Encoding UTF8
