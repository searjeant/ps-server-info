# ps-server-info

PowerShell scripts for retrieving configuration information from remote systems.
These are quite crude scripts bt they served a useful purpose, when surveying a large number of remote Windows systems.

## Modifications for cross-OS application
As they stand now (Oct 2025) the scripts will not run on Linux. PowerShell can be installed on Linux but not all functions used in the original scripts are available in Linux. 
This is annoying - PowerShell is now cross-platform, so there should be platform-independent functions in the standard library which are bound to platform-specific underlying implementations in each OS.  

### Computer Information
`Get-ComputerInfo` does not work on non-Windows systems. 
There are some other ways to get system information from Linux, notable the Cim-family of functions (CIM = Common Information Model).
See: 
And this library function: [linuxinfo](https://www.powershellgallery.com/packages/linuxinfo/1.0.1/Content/public%5CGet-ComputerInfo.ps1)

### TCP Connections
Another function not present in Linux PowerShell is  `Get-NetTCPConnection` which the Windows scripts use to get TCP connection information.
