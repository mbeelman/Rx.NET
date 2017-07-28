$scriptPath = split-path -parent $MyInvocation.MyCommand.Definition

$configuration = "Release"

$isAppVeyor = Test-Path -Path env:\APPVEYOR
$outputLocation = Join-Path $scriptPath "testResults"
$xUnitConsolePath = ".\packages\xunit.runner.console\tools\net452\xunit.console.exe"
$rootPath = (Resolve-Path .).Path
$artifacts = Join-Path $rootPath "artifacts"


$signClientSettings = Join-Path (Join-Path (Get-Item $scriptPath).Parent.Parent.FullName "scripts") "SignClientSettings.json"
$hasSignClientSecret = !([string]::IsNullOrEmpty($env:SignClientSecret))
$signClientAppPath = Join-Path (Join-Path (Join-Path .\Packages "SignClient") "Tools") "SignClient.dll"

#remove any old coverage file
md -Force $outputLocation | Out-Null
$outputPath = (Resolve-Path $outputLocation).Path
$outputFileDotCover1 = Join-Path $outputPath -childpath 'coverage-ix1.dcvr'
$outputFileDotCover2 = Join-Path $outputPath -childpath 'coverage-ix2.dcvr'
$outputFileDotCover = Join-Path $outputPath -childpath 'coverage-ix.dcvr'
$outputFile = Join-Path $outputPath -childpath 'coverage-ix.xml'
Remove-Item $outputPath -Force -Recurse
md -Force $outputLocation | Out-Null

if (!(Test-Path .\nuget.exe)) {
    wget "https://dist.nuget.org/win-x86-commandline/v4.0.0/nuget.exe" -outfile .\nuget.exe
}

# get tools
.\nuget.exe install -excludeversion SignClient -Version 0.7.0 -outputdirectory packages
.\nuget.exe install -excludeversion JetBrains.dotCover.CommandLineTools -pre -outputdirectory packages
.\nuget.exe install -excludeversion gitversion.commandline -pre -outputdirectory packages
.\nuget.exe install -excludeversion xunit.runner.console -pre -outputdirectory packages
.\nuget.exe install -excludeversion ReportGenerator -outputdirectory packages
#.\nuget.exe install -excludeversion coveralls.io -outputdirectory packages
.\nuget.exe install -excludeversion coveralls.io.dotcover -outputdirectory packages


.\packages\gitversion.commandline\tools\gitversion.exe /l console /output buildserver
$versionObj = .\packages\gitversion.commandline\tools\gitversion.exe | ConvertFrom-Json
$packageSemVer = $versionObj.FullSemVer

New-Item -ItemType Directory -Force -Path $artifacts


Write-Host "Restoring packages for $scriptPath\Ix.NET.sln" -Foreground Green
# use nuget.exe to restore on the legacy proj type
.\nuget.exe restore "$scriptPath\System.Interactive.Tests.Uwp.DeviceRunner\System.Interactive.Tests.Uwp.DeviceRunner.csproj"
msbuild "$scriptPath\Ix.NET.sln" /m /t:restore /p:Configuration=$configuration 
# Force a restore again to get proper version numbers https://github.com/NuGet/Home/issues/4337
msbuild "$scriptPath\Ix.NET.sln" /m /t:restore /p:Configuration=$configuration 

Write-Host "Building $scriptPath\Ix.NET.sln" -Foreground Green
msbuild "$scriptPath\Ix.NET.sln" /m /t:build /p:Configuration=$configuration 
if ($LastExitCode -ne 0) { 
        Write-Host "Error with build" -Foreground Red
        if($isAppVeyor) {
          $host.SetShouldExit($LastExitCode)
          exit $LastExitCode
        }  
}


Write-Host "Building Packages" -Foreground Green
msbuild "$scriptPath\System.Interactive\System.Interactive.csproj" /t:pack /p:Configuration=$configuration /p:PackageOutputPath=$artifacts /p:NoPackageAnalysis=true
msbuild "$scriptPath\System.Interactive.Async\System.Interactive.Async.csproj" /t:pack /p:Configuration=$configuration /p:PackageOutputPath=$artifacts /p:NoPackageAnalysis=true
msbuild "$scriptPath\System.Interactive.Async.Providers\System.Interactive.Async.Providers.csproj" /t:pack /p:Configuration=$configuration /p:PackageOutputPath=$artifacts /p:NoPackageAnalysis=true
msbuild "$scriptPath\System.Interactive.Providers\System.Interactive.Providers.csproj" /t:pack /p:Configuration=$configuration /p:PackageOutputPath=$artifacts /p:NoPackageAnalysis=true

if($hasSignClientSecret) {
  Write-Host "Signing Packages" -Foreground Green	
  $nupgks = ls $artifacts\*Interact*.nupkg | Select -ExpandProperty FullName

  foreach ($nupkg in $nupgks) {
    Write-Host "Submitting $nupkg for signing"

    dotnet $signClientAppPath 'sign' -c $signClientSettings -i $nupkg -s $env:SignClientSecret -n 'Ix.NET' -d 'Interactive Extensions for .NET' -u 'http://reactivex.io/' 

    if ($LastExitCode -ne 0) { 
        Write-Host "Error signing $nupkg" -Foreground Red
        if($isAppVeyor) {
          $host.SetShouldExit($LastExitCode)
          exit $LastExitCode
        }  
    }
    Write-Host "Finished signing $nupkg"
  }

} else {
  Write-Host "Client Secret not found, not signing packages"
}

Write-Host "Running tests" -Foreground Green
$testDirectory = Join-Path $scriptPath "Tests"  

# OpenCover isn't working currently. So run tests on CI and coverage with JetBrains 

# Run .NET Core only for now until perf improves on the runner for .net desktop
$dotnet = "$env:ProgramFiles\dotnet\dotnet.exe"
.\packages\JetBrains.dotCover.CommandLineTools\tools\dotCover.exe cover /targetexecutable="$dotnet" /targetworkingdir="$testDirectory" /targetarguments="test -c $configuration --no-build -f netcoreapp1.0" /output="$outputFileDotCover1" /Filters="+:module=System.Interactive;+:module=System.Interactive.Async;+:module=System.Interactive.Providers;+:module=System.Interactive.Async.Providers;-:type=Xunit*" /DisableDefaultFilters /ReturnTargetExitCode /AttributeFilters="System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverageAttribute"

if ($LastExitCode -ne 0) { 
	Write-Host "Error with tests" -Foreground Red
	if($isAppVeyor) {
	  $host.SetShouldExit($LastExitCode)
	  exit $LastExitCode
	}  
}

# run .net desktop tests
.\packages\JetBrains.dotCover.CommandLineTools\tools\dotCover.exe cover /targetexecutable="$xUnitConsolePath" /targetworkingdir="$testDirectory\bin\$configuration\net461\" /targetarguments="Tests.dll" /output="$outputFileDotCover2" /Filters="+:module=System.Interactive;+:module=System.Interactive.Async;+:module=System.Interactive.Providers;+:module=System.Interactive.Async.Providers;-:type=Xunit*" /DisableDefaultFilters /ReturnTargetExitCode /AttributeFilters="System.Diagnostics.CodeAnalysis.ExcludeFromCodeCoverageAttribute"

if ($LastExitCode -ne 0) { 
	Write-Host "Error with tests" -Foreground Red
	if($isAppVeyor) {
	  $host.SetShouldExit($LastExitCode)
	  exit $LastExitCode
	}  
}

# For perf, we need to use the xunit console runner, but that generates two reports. merge into one and generate the detailed xml output

.\packages\JetBrains.dotCover.CommandLineTools\tools\dotCover.exe merge /Source="$outputFileDotCover1;$outputFileDotCover2" /Output="$outputFileDotCover"
.\packages\JetBrains.dotCover.CommandLineTools\tools\dotCover.exe report /Source="$outputFileDotCover" /Output="$outputFile" /ReportType=DetailedXML /HideAutoProperties


# Either display or publish the results
if ($env:CI -eq 'True')
{
  .\packages\coveralls.io.dotcover\tools\coveralls.net.exe  -p DotCover "$outputFile"
}
else
{
  .\packages\ReportGenerator\tools\ReportGenerator.exe -reports:"$outputFile" -targetdir:"$outputPath"
  &"$outPutPath/index.htm"
}
