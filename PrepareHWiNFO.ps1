param([switch]$ValidateOnly)
$ErrorActionPreference='Stop'
function Set-IniOption([string]$text,[string]$name,[string]$value) {
    $section=[regex]::Match($text,'(?ims)(^\[Settings\][ \t]*\r?\n)(.*?)(?=^\[|\z)')
    if(-not $section.Success){return "[Settings]`r`n$name=$value`r`n`r`n"+$text}
    $body=[regex]::Replace($section.Groups[2].Value,'(?im)^'+[regex]::Escape($name)+'[ \t]*=.*(?:\r?\n|$)','')
    if($body.Length -gt 0 -and -not $body.EndsWith("`n")){$body+="`r`n"}
    $body+="$name=$value`r`n"
    return $text.Substring(0,$section.Index)+$section.Groups[1].Value+$body+$text.Substring($section.Index+$section.Length)
}
function Get-StartupOptions([bool]$startSensors) {
    $result=[ordered]@{RememberPreferences='1'}
    if($startSensors){$result.OpenSensors='1';$result.MinimalizeSensors='1';$result.MinimalizeSensorsClose='1'}
    return $result
}
if($ValidateOnly){
    $original="[Settings]`r`nTheme=1`r`nRememberPreferences=0`r`nSensorsOnly=0`r`nMinimalizeMainWnd=0`r`nOpenSensors=0`r`nMinimalizeSensors=0`r`nMinimalizeSensorsClose=0`r`nShowWelcomeAndProgress=1`r`n`r`n[Other]`r`nRememberPreferences=0`r`n"
    $fixture=$original;$options=Get-StartupOptions $true
    foreach($name in $options.Keys){$fixture=Set-IniOption $fixture $name $options[$name]}
    if($fixture -notmatch '(?m)^RememberPreferences=1\r?$' -or $fixture -notmatch '\[Other\]\r?\nRememberPreferences=0'){throw 'INI sections were not preserved.'}
    if($fixture -notmatch '(?m)^Theme=1\r?$'){throw 'An unrelated setting was lost.'}
    if($fixture -notmatch '(?m)^SensorsOnly=0\r?$' -or $fixture -notmatch '(?m)^MinimalizeMainWnd=0\r?$' -or $fixture -notmatch '(?m)^ShowWelcomeAndProgress=1\r?$'){throw 'Main window or welcome preferences were overwritten.'}
    foreach($sensorOption in @('OpenSensors','MinimalizeSensors','MinimalizeSensorsClose')){if($fixture -notmatch ('(?m)^'+$sensorOption+'=1\r?$')){throw "Background sensors not enabled: $sensorOption"}}
    $unmanaged=$original;$unmanagedOptions=Get-StartupOptions $false
    foreach($name in $unmanagedOptions.Keys){$unmanaged=Set-IniOption $unmanaged $name $unmanagedOptions[$name]}
    foreach($sensorOption in @('OpenSensors','MinimalizeSensors','MinimalizeSensorsClose')){if($unmanaged -notmatch ('(?m)^'+$sensorOption+'=0\r?$')){throw "Opt-out did not preserve $sensorOption"}}
    $again=$fixture;foreach($name in $options.Keys){$again=Set-IniOption $again $name $options[$name]}
    if($again -ne $fixture){throw 'Repeated startup preparation must not duplicate settings.'}
    Write-Output 'PASS: background sensors, main window preferences, opt-out, section boundaries and repeated startup.'
    return
}
$config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'panel.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not [IO.Path]::IsPathRooted($config.hwinfoPath)){$config.hwinfoPath=Join-Path $PSScriptRoot $config.hwinfoPath}
if(-not $config.startup.enabled){return}
if(@(Get-Process -Name HWiNFO64 -ErrorAction SilentlyContinue).Count -gt 0){return}
$options=Get-StartupOptions ($config.startup.startSensors -ne $false)
if(-not (Test-Path -LiteralPath $config.hwinfoPath)){throw '找不到 panel.json 中指定的 HWiNFO64.exe。'}
$iniPath=Join-Path (Split-Path -LiteralPath $config.hwinfoPath) 'HWiNFO64.INI'
$text="[Settings]`r`n"
if(Test-Path -LiteralPath $iniPath){
    $text=[IO.File]::ReadAllText($iniPath)
    $backupPath=Join-Path $PSScriptRoot 'HWiNFO64.INI.before-repair'
    if(-not (Test-Path -LiteralPath $backupPath)){Copy-Item -LiteralPath $iniPath -Destination $backupPath}
}
foreach($name in $options.Keys){$text=Set-IniOption $text $name $options[$name]}
[IO.File]::WriteAllText($iniPath,$text,[Text.UTF8Encoding]::new($false))
if($config.startup.restoreOutputProfile){
    $restorePath=Join-Path $PSScriptRoot 'RestoreHWiNFO.reg'
    if(-not (Test-Path -LiteralPath $restorePath)){throw '找不到 RestoreHWiNFO.reg，未启动 HWiNFO。'}
    & (Join-Path $env:SystemRoot 'System32\reg.exe') import $restorePath | Out-Null
    if($LASTEXITCODE -ne 0){throw '九项传感器输出配置导入失败。'}
}
Start-Process -FilePath $config.hwinfoPath -WorkingDirectory (Split-Path -LiteralPath $config.hwinfoPath) -WindowStyle Normal
