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
$options=[ordered]@{RememberPreferences='1';SensorsOnly='1';MinimalizeSensors='1';MinimalizeSensorsClose='1';ShowWelcomeAndProgress='0';OpenSystemSummary='0'}
if($ValidateOnly){
    $fixture="[Settings]`r`nTheme=1`r`nRememberPreferences=0`r`n`r`n[Other]`r`nRememberPreferences=0`r`n"
    foreach($name in $options.Keys){$fixture=Set-IniOption $fixture $name $options[$name]}
    if($fixture -notmatch '(?m)^RememberPreferences=1\r?$' -or $fixture -notmatch '\[Other\]\r?\nRememberPreferences=0'){throw 'INI sections were not preserved.'}
    if($fixture -notmatch '(?m)^Theme=1\r?$'){throw 'An unrelated setting was lost.'}
    $again=$fixture;foreach($name in $options.Keys){$again=Set-IniOption $again $name $options[$name]}
    if($again -ne $fixture){throw 'Repeated startup preparation must not duplicate settings.'}
    Write-Output 'PASS: persistence options, unrelated settings, section boundaries and repeated startup.'
    return
}
$config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'panel.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not [IO.Path]::IsPathRooted($config.hwinfoPath)){$config.hwinfoPath=Join-Path $PSScriptRoot $config.hwinfoPath}
if(-not $config.startup.enabled){return}
if(@(Get-Process -Name HWiNFO64 -ErrorAction SilentlyContinue).Count -gt 0){return}
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
Start-Process -FilePath $config.hwinfoPath -WorkingDirectory (Split-Path -LiteralPath $config.hwinfoPath) -WindowStyle Hidden
