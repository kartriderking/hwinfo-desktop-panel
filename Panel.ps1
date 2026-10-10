param([switch]$ValidateOnly, [string]$PreviewPath, [switch]$ExpandDetails)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
Add-Type -Path (Join-Path $PSScriptRoot 'NativeTelemetry.cs')
$config=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'panel.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if(-not [IO.Path]::IsPathRooted($config.hwinfoPath)){$config.hwinfoPath=Join-Path $PSScriptRoot $config.hwinfoPath}
if(-not $ValidateOnly -and -not $PreviewPath){
    try{& (Join-Path $PSScriptRoot 'PrepareHWiNFO.ps1')}
    catch{[void][Windows.MessageBox]::Show('启动准备失败：'+$_.Exception.Message,'硬件监控')}
}
foreach($spec in @($config.sensors)+@($config.metrics)) {
    [void][regex]::new($spec.sensorPattern); [void][regex]::new($spec.labelPattern)
}
[void][PanelNative]::ReadSystem()
function Get-ReadingUnit([string]$text) {
    if($text -match '(°\s*C|℃)') { return 'C' }
    if($text -match 'RPM|转/分') { return 'RPM' }
    if($text -match 'MHz') { return 'MHz' }
    if($text -match '(^|\s)W($|\s)|瓦') { return 'W' }
    if($text -match '%') { return '%' }
    if($text -match '^(Yes|No|是|否|True|False)$') { return 'bool' }
    return ''
}
function Get-HwReadings {
    foreach($hive in @([Microsoft.Win32.Registry]::CurrentUser,[Microsoft.Win32.Registry]::LocalMachine)) {
        $key=$hive.OpenSubKey('SOFTWARE\HWiNFO64\VSB'); if($null -eq $key) { continue }
        try {
            if(([DateTime]::UtcNow-[PanelNative]::RegistryTime($key.Handle)).TotalSeconds -gt $config.staleSeconds) { continue }
            $found=@()
            foreach($name in $key.GetValueNames()) {
                if($name -notmatch '^ValueRaw(\d+)$') { continue }
                $index=$Matches[1]; $formatted=([string]$key.GetValue("Value$index")).Trim()
                $unit=Get-ReadingUnit $formatted; if(-not $unit) { continue }
                $number=0.0; $raw=[string]$key.GetValue($name)
                $parsed=[double]::TryParse($raw,[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$number)
                if(-not $parsed) { $parsed=[double]::TryParse($raw,[ref]$number) }
                if($unit -eq 'bool') {
                    if($formatted -match '^(Yes|是|True)$') { $number=1; $parsed=$true }
                    elseif($formatted -match '^(No|否|False)$') { $number=0; $parsed=$true }
                }
                if(-not $parsed -or [double]::IsNaN($number) -or [double]::IsInfinity($number)) { continue }
                $found += [pscustomobject]@{Sensor=[string]$key.GetValue("Sensor$index");Label=[string]$key.GetValue("Label$index");Value=$number;Unit=$unit}
            }
            if($found.Count -gt 0) { return $found }
        } finally { $key.Dispose() }
    }
    return @()
}
function Resolve-Reading($spec,$readings) {
    $unit='C'; if($spec.unit) { $unit=$spec.unit }
    $candidates=@($readings | Where-Object { $_.Unit -eq $unit -and $_.Sensor -match $spec.sensorPattern -and $_.Label -match $spec.labelPattern })
    if($candidates.Count -eq 0) { return $null }
    if($spec.aggregate -eq 'max') { return ($candidates | Sort-Object Value -Descending | Select-Object -First 1) }
    return ($candidates | Sort-Object @{Expression={if($_.Sensor -match 'DTS'){0}else{1}}},Label | Select-Object -First 1)
}
function Brush([string]$color) { return [Windows.Media.BrushConverter]::new().ConvertFromString($color) }
function Get-HwSourceHint([bool]$running,[int]$readingCount,[int]$activeCount) {
    if(-not $running){return [pscustomobject]@{Text='HWiNFO 未运行 · 系统/显卡信息继续更新';Tip='请启动 HWiNFO 并开启传感器采集。'}}
    if($readingCount -eq 0){return [pscustomobject]@{Text='未收到传感器输出 · 点 HWiNFO 检查';Tip='HWiNFO 进程已运行，但没有新鲜的 Gadget 数据。请在主窗口点“传感器”，并确认 Gadget 输出已启用。传感器窗口可以最小化；停止采集或退出 HWiNFO 后，温度与 RPM 会断连。'}}
    if($activeCount -eq 0){return [pscustomobject]@{Text='已收到输出 · 请核对温度项目';Tip='传感器输出正在更新，但未匹配温度项目。请核对 Gadget 勾选项目及 panel.json 的设备名、项目名和单位。'}}
    return $null
}
[xml]$xaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="硬件监控" WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" Background="Transparent" SizeToContent="Height" ShowInTaskbar="True" FontFamily="Microsoft YaHei UI">
 <Border Background="#111827" BorderBrush="#334155" BorderThickness="1" CornerRadius="16" Padding="16">
  <StackPanel>
   <Grid x:Name="Header" Background="Transparent" Margin="0,0,0,10">
    <Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
    <StackPanel><TextBlock Text="硬件监控" Foreground="#F1F5F9" FontSize="17" FontWeight="SemiBold"/><TextBlock Text="温度 · 风扇 · 负载" Foreground="#94A3B8" FontSize="9" Margin="0,3,0,0"/></StackPanel>
    <Button x:Name="CloseButton" Grid.Column="1" Content="×" Width="24" Height="24" VerticalAlignment="Top" Background="#1E293B" Foreground="#CBD5E1" BorderThickness="0" ToolTip="关闭面板"/>
   </Grid>
   <ScrollViewer x:Name="Body" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
    <StackPanel>
     <StackPanel x:Name="Cards"/>
     <Border Background="#1B2638" CornerRadius="9" Padding="10" Margin="0,0,0,8"><StackPanel><TextBlock x:Name="MemoryText" Foreground="#E2E8F0" FontSize="11"/><ProgressBar x:Name="MemoryBar" Height="3" Margin="0,6,0,0" Maximum="100" Foreground="#38BDF8" Background="#334155" BorderThickness="0"/></StackPanel></Border>
     <Border Background="#1B2638" CornerRadius="9" Padding="10" Margin="0,0,0,8"><StackPanel><TextBlock Text="磁盘" Foreground="#F1F5F9" FontSize="12" FontWeight="SemiBold" Margin="0,0,0,4"/><StackPanel x:Name="Disks"/></StackPanel></Border>
     <Border x:Name="SystemFansBox" Background="#1B2638" CornerRadius="9" Padding="10"><Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><TextBlock Text="系统 / 辅助风扇" Foreground="#94A3B8" FontSize="10" VerticalAlignment="Center"/><TextBlock x:Name="SystemFansValue" Grid.Column="1" Text="-- / -- RPM" Foreground="#64748B" FontSize="11" VerticalAlignment="Center"/></Grid></Border>
     <StackPanel x:Name="Details" Visibility="Collapsed" Margin="0,10,0,0"><TextBlock Text="本次温度峰值" Foreground="#94A3B8" FontSize="10" Margin="0,0,0,5"/><StackPanel x:Name="PeakRows"/><TextBlock x:Name="DiagnosticHeading" Text="诊断信息" Foreground="#94A3B8" FontSize="10" Margin="0,10,0,5" Visibility="Collapsed"/><StackPanel x:Name="DetailRows"/><Button x:Name="ResetPeaks" Content="重置温度峰值" Margin="0,8,0,0" Background="#1E293B" Foreground="#E2E8F0" BorderThickness="0" Padding="6"/></StackPanel>
    </StackPanel>
   </ScrollViewer>
   <TextBlock x:Name="Status" Foreground="#94A3B8" FontSize="10" TextWrapping="Wrap" Margin="0,10,0,10"/>
   <Grid><Grid.ColumnDefinitions><ColumnDefinition/><ColumnDefinition/><ColumnDefinition/></Grid.ColumnDefinitions>
    <Button x:Name="OpenHw" Content="HWiNFO" Background="#1E293B" Foreground="#E2E8F0" BorderThickness="0" Padding="6" Margin="0,0,5,0"/>
    <Button x:Name="DetailsButton" Grid.Column="1" Content="详情" Background="#1E293B" Foreground="#E2E8F0" BorderThickness="0" Padding="6" Margin="0,0,5,0"/>
    <Button x:Name="HelpButton" Grid.Column="2" Content="说明" Background="#1E293B" Foreground="#E2E8F0" BorderThickness="0" Padding="6"/>
   </Grid>
  </StackPanel>
 </Border>
</Window>
'@
$window=[Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
$window.Width=[Math]::Max(300,[Math]::Min(600,$config.width)); $window.Topmost=[bool]$config.topmost
$window.Opacity=[Math]::Max(0.4,[Math]::Min(1,$config.opacity))
$window.Left=[Math]::Max(0,[Windows.SystemParameters]::WorkArea.Right-$window.Width-24)
$window.Top=[Windows.SystemParameters]::WorkArea.Top+24
$window.FindName('Body').MaxHeight=[Math]::Max(240,[Windows.SystemParameters]::WorkArea.Height-170)
$status=$window.FindName('Status')
if($ExpandDetails){$window.FindName('Details').Visibility=[Windows.Visibility]::Visible;$window.FindName('DetailsButton').Content='收起'}
$script:rows=@(); $script:peaks=@{}; $script:peakViews=@{}; $script:detailViews=@{}; $script:metricReadings=@{}
$script:cpuLoad=$null; $script:gpuLoad=$null; $script:timer=$null
function New-Text([string]$text,[double]$size=10,[string]$color='#94A3B8') {
    $t=[Windows.Controls.TextBlock]::new(); $t.Text=$text; $t.FontSize=$size; $t.Foreground=Brush $color; return $t
}
foreach($spec in $config.sensors | Where-Object {$_.name -in @('CPU','GPU')}) {
    $card=[Windows.Controls.Border]::new(); $card.Background=Brush '#1B2638'
    $card.CornerRadius=[Windows.CornerRadius]::new(9); $card.Padding=[Windows.Thickness]::new(10)
    $card.Margin=[Windows.Thickness]::new(0,0,0,8)
    $stack=[Windows.Controls.StackPanel]::new(); $grid=[Windows.Controls.Grid]::new()
    [void]$grid.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $col=[Windows.Controls.ColumnDefinition]::new(); $col.Width=[Windows.GridLength]::Auto
    [void]$grid.ColumnDefinitions.Add($col)
    $left=[Windows.Controls.StackPanel]::new(); $label=New-Text $spec.name 12 '#F1F5F9'
    $label.FontWeight=[Windows.FontWeights]::SemiBold
    $left.VerticalAlignment=[Windows.VerticalAlignment]::Center
    [void]$left.Children.Add($label)
    $right=[Windows.Controls.StackPanel]::new(); $value=New-Text '-- °C' 24 '#64748B'
    $value.FontFamily=[Windows.Media.FontFamily]::new('Segoe UI'); $value.HorizontalAlignment=[Windows.HorizontalAlignment]::Right
    $peak=New-Text '峰值 --' 9; $peak.HorizontalAlignment=[Windows.HorizontalAlignment]::Right
    $peak.ToolTip='本面板启动或重置以来，每次轮询采集到的最高温度。'
    [void]$right.Children.Add($value); [void]$right.Children.Add($peak); [Windows.Controls.Grid]::SetColumn($right,1)
    [void]$grid.Children.Add($left); [void]$grid.Children.Add($right); [void]$stack.Children.Add($grid)
    $extra=New-Text '' 10; $extra.Margin=[Windows.Thickness]::new(0,3,0,0); [void]$stack.Children.Add($extra)
    $secondary=$null
    if($spec.name -eq 'GPU'){$secondary=New-Text '' 10;$secondary.Margin=[Windows.Thickness]::new(0,3,0,0);[void]$stack.Children.Add($secondary)}
    $card.Child=$stack; [void]$window.FindName('Cards').Children.Add($card)
    $script:rows += [pscustomobject]@{Spec=$spec;Card=$card;Value=$value;Peak=$peak;Extra=$extra;Secondary=$secondary}
}
function New-Line([string]$name,$parent) {
    $g=[Windows.Controls.Grid]::new(); $g.Margin=[Windows.Thickness]::new(0,3,0,3)
    [void]$g.ColumnDefinitions.Add([Windows.Controls.ColumnDefinition]::new())
    $col=[Windows.Controls.ColumnDefinition]::new(); $col.Width=[Windows.GridLength]::Auto; [void]$g.ColumnDefinitions.Add($col)
    $label=New-Text $name 10; $value=New-Text '未提供' 11 '#64748B'; [Windows.Controls.Grid]::SetColumn($value,1)
    [void]$g.Children.Add($label); [void]$g.Children.Add($value); [void]$parent.Children.Add($g)
    return [pscustomobject]@{Grid=$g;Value=$value}
}
foreach($spec in $config.sensors | Where-Object {$_.name -notin @('CPU','GPU')}){
    $label=$spec.name
    if($spec.subtitle -match '^([A-Z]:)'){$kind='HDD';if($spec.name -eq 'SSD'){$kind='SSD'};$label=$Matches[1]+'  '+$kind}
    $view=New-Line $label $window.FindName('Disks');$view.Value.FontSize=14;$view.Value.FontFamily=[Windows.Media.FontFamily]::new('Segoe UI')
    $script:rows += [pscustomobject]@{Spec=$spec;Card=$view.Grid;Value=$view.Value;Peak=$null;Extra=$null;Secondary=$null}
}
foreach($spec in $config.sensors){
    $label=$spec.name
    if($spec.subtitle -match '^([A-Z]:)'){$label=$Matches[1]+' · '+$spec.name}
    $script:peakViews[$spec.name]=New-Line $label $window.FindName('PeakRows')
}
foreach($spec in $config.metrics | Where-Object {$_.id -notmatch 'Fan$'}) {
    $script:detailViews[$spec.id]=New-Line $spec.name $window.FindName('DetailRows')
    $script:detailViews[$spec.id].Grid.Visibility=[Windows.Visibility]::Collapsed
}
function Get-FanDisplay([string]$id,$gpu){
    $reading=$script:metricReadings[$id]
    if($null -ne $reading){return [pscustomobject]@{Text=('{0:0} RPM' -f $reading.Value);Tip="$($reading.Sensor) / $($reading.Label) · 接口名称以实际接线为准。"}}
    if($id -eq 'gpuFan' -and $gpu -and $null -ne $gpu.FanPercent){return [pscustomobject]@{Text=('控制 {0:0} %' -f $gpu.FanPercent);Tip='NVIDIA 驱动的控制比例，不是实际 RPM。'}}
    return [pscustomobject]@{Text='未提供';Tip='此 RPM 传感器未输出或数据已过期。'}
}
function Update-Panel {
    try {
        $running=@(Get-Process -Name HWiNFO64 -ErrorAction SilentlyContinue).Count -gt 0
        $readings=@(); if($running) { $readings=@(Get-HwReadings) }
        $system=[PanelNative]::ReadSystem(); $gpu=[PanelNative]::ReadGpu()
        if($gpu -and $gpu.Name -notmatch $config.gpuPattern) { $gpu=$null }
        $script:cpuLoad=$system.CpuPercent; $script:gpuLoad=$null; if($gpu) { $script:gpuLoad=$gpu.Utilization }
        $active=0; $script:metricReadings=@{}
        foreach($spec in $config.metrics) { $script:metricReadings[$spec.id]=Resolve-Reading $spec $readings }
        $cpuFan=Get-FanDisplay 'cpuFan' $gpu;$gpuFan=Get-FanDisplay 'gpuFan' $gpu
        foreach($row in $script:rows) {
            $reading=Resolve-Reading $row.Spec $readings; $color='#64748B'
            if($null -ne $reading) {
                $active++; $row.Value.Text='{0:0} °C' -f $reading.Value; $color='#38BDF8'
                if($reading.Value -ge $row.Spec.warm) {$color='#FBBF24'}; if($reading.Value -ge $row.Spec.hot) {$color='#FB7185'}
                if(-not $script:peaks.ContainsKey($row.Spec.name) -or $reading.Value -gt $script:peaks[$row.Spec.name]) {$script:peaks[$row.Spec.name]=$reading.Value}
                $row.Card.ToolTip=$row.Spec.subtitle+"`n$($reading.Sensor) / $($reading.Label) · $($reading.Value) °C"
            } else { $row.Value.Text='-- °C'; $row.Card.ToolTip=$row.Spec.subtitle+"`n数据未输出、HWiNFO 已退出，或接口超过 30 秒未更新。" }
            $row.Value.Foreground=Brush $color
            $peakText='峰值 --';$peakValue='--'
            if($script:peaks.ContainsKey($row.Spec.name)){$peakText='峰值 {0:0} °C' -f $script:peaks[$row.Spec.name];$peakValue='{0:0} °C' -f $script:peaks[$row.Spec.name]}
            if($null -ne $row.Peak){$row.Peak.Text=$peakText}
            $script:peakViews[$row.Spec.name].Value.Text=$peakValue
            $script:peakViews[$row.Spec.name].Value.Foreground=Brush '#E2E8F0'
            $script:peakViews[$row.Spec.name].Grid.ToolTip=$row.Spec.subtitle+' · 本面板本次运行期间采集到的最高温度。'
            if($row.Spec.name -eq 'CPU') {
                $load='采样中';if($null -ne $script:cpuLoad){$load='{0:0} %' -f $script:cpuLoad}
                $row.Extra.Text="负载 $load · 风扇 $($cpuFan.Text)"
                $row.Extra.ToolTip="Windows 全部逻辑核心平均负载。`n$($cpuFan.Tip)"
            }
            if($row.Spec.name -eq 'GPU') {
                $load='--'; $memory='--'
                if($gpu -and $null -ne $gpu.Utilization) {$load='{0:0} %' -f $gpu.Utilization}
                if($gpu -and $null -ne $gpu.MemoryUsedGB) {$memory='{0:0.0} / {1:0.0} GB' -f $gpu.MemoryUsedGB,$gpu.MemoryTotalGB}
                $row.Extra.Text="负载 $load · 风扇 $($gpuFan.Text)";$row.Extra.ToolTip="NVIDIA GPU 利用率。`n$($gpuFan.Tip)"
                $row.Secondary.Text="显存 $memory";$row.Secondary.ToolTip='NVIDIA NVML 提供的帧缓冲显存占用。'
            }
        }
        $sysFan=Get-FanDisplay 'sysFan' $gpu;$auxFan=Get-FanDisplay 'auxFan' $gpu
        $sysValue='--';$auxValue='--'
        if($null -ne $script:metricReadings['sysFan']){$sysValue='{0:0}' -f $script:metricReadings['sysFan'].Value}
        if($null -ne $script:metricReadings['auxFan']){$auxValue='{0:0}' -f $script:metricReadings['auxFan'].Value}
        $window.FindName('SystemFansValue').Text="$sysValue / $auxValue RPM"
        $window.FindName('SystemFansValue').Foreground=Brush '#E2E8F0'
        $window.FindName('SystemFansBox').ToolTip="系统接口 SYSFANIN：$($sysFan.Text)`n$($sysFan.Tip)`n`n辅助接口 AUXFANIN3：$($auxFan.Text)`n$($auxFan.Tip)"
        $diagnosticCount=0
        foreach($id in $script:detailViews.Keys) {
            $view=$script:detailViews[$id]; $reading=$script:metricReadings[$id]
            $view.Value.Text='--'; $view.Value.Foreground=Brush '#64748B'; $view.Grid.ToolTip='此项尚未启用 Gadget 输出，或硬件未提供。'
            $view.Grid.Visibility=[Windows.Visibility]::Collapsed
            if($null -ne $reading) {
                $view.Grid.Visibility=[Windows.Visibility]::Visible;$diagnosticCount++
                $view.Value.Foreground=Brush '#E2E8F0'; $view.Grid.ToolTip="$($reading.Sensor) / $($reading.Label)"
                switch($reading.Unit) {
                    'bool' {if($reading.Value -gt 0){$view.Value.Text='是';$view.Value.Foreground=Brush '#FB7185'}else{$view.Value.Text='否'}}
                    'C' {$view.Value.Text='{0:0} °C' -f $reading.Value}
                    'W' {$view.Value.Text='{0:0.0} W' -f $reading.Value}
                    'MHz' {$view.Value.Text='{0:0} MHz' -f $reading.Value}
                }
            } elseif($id -eq 'gpuPower' -and $gpu -and $null -ne $gpu.PowerWatts) {
                $view.Grid.Visibility=[Windows.Visibility]::Visible;$diagnosticCount++
                $view.Value.Text='{0:0.0} W' -f $gpu.PowerWatts; $view.Value.Foreground=Brush '#E2E8F0'; $view.Grid.ToolTip='NVIDIA NVML 功耗遥测。'
            }
        }
        $window.FindName('DiagnosticHeading').Visibility=[Windows.Visibility]::Collapsed
        if($diagnosticCount -gt 0){$window.FindName('DiagnosticHeading').Visibility=[Windows.Visibility]::Visible}
        if($system.MemoryTotalGB -gt 0) {
            $window.FindName('MemoryText').Text='内存  {0:0.0} / {1:0.0} GB · {2} %' -f $system.MemoryUsedGB,$system.MemoryTotalGB,$system.MemoryPercent
            $window.FindName('MemoryBar').Value=$system.MemoryPercent; $memoryColor='#38BDF8'
            if($system.MemoryPercent -ge 90){$memoryColor='#FBBF24'}; $window.FindName('MemoryBar').Foreground=Brush $memoryColor
        } else {$window.FindName('MemoryText').Text='内存数据未提供';$window.FindName('MemoryBar').Value=0}
        $fanCount=0;foreach($id in @('cpuFan','gpuFan','sysFan','auxFan')){if($null -ne $script:metricReadings[$id]){$fanCount++}}
        $status.Text="温度 $active / $($script:rows.Count) · 风扇 $fanCount / 4 已连接"
        $status.Foreground=Brush '#94A3B8';if($active -lt $script:rows.Count -or $fanCount -lt 4){$status.Foreground=Brush '#FBBF24'}
        $status.ToolTip='更新于 '+(Get-Date -Format 'HH:mm:ss')+'。温度及 RPM 来自 HWiNFO；负载/内存来自 Windows/NVIDIA。峰值为本面板本次运行轮询采集的最高值。'
        $sourceHint=Get-HwSourceHint $running $readings.Count $active
        if($null -ne $sourceHint){$status.Text=$sourceHint.Text;$status.ToolTip=$sourceHint.Tip;$status.Foreground=Brush '#FBBF24'}
        $thermalAlerts=@();foreach($id in @('cpuThrottle','gpuThrottle')){if($null -ne $script:metricReadings[$id] -and $script:metricReadings[$id].Value -gt 0){if($id -eq 'cpuThrottle'){$thermalAlerts+='CPU 热降频'}else{$thermalAlerts+='GPU 温度限制'}}}
        if($thermalAlerts.Count -gt 0){$status.Text+=' · '+($thermalAlerts -join ' / ');$status.Foreground=Brush '#FB7185'}
    } catch {$status.Text='读取失败：'+$_.Exception.Message}
}
$window.FindName('Header').Add_MouseLeftButtonDown({if($_.ChangedButton -eq [Windows.Input.MouseButton]::Left){$window.DragMove()}})
$window.FindName('CloseButton').Add_Click({$window.Close()})
$window.FindName('OpenHw').Add_Click({if(Test-Path -LiteralPath $config.hwinfoPath){Start-Process -FilePath $config.hwinfoPath}else{[void][Windows.MessageBox]::Show('找不到 HWiNFO，请修改 panel.json 的 hwinfoPath。','硬件监控')}})
$window.FindName('HelpButton').Add_Click({Start-Process -FilePath 'notepad.exe' -ArgumentList ('"'+(Join-Path $PSScriptRoot 'README.md')+'"')})
$window.FindName('DetailsButton').Add_Click({
    $details=$window.FindName('Details');$button=$window.FindName('DetailsButton')
    if($details.Visibility -eq [Windows.Visibility]::Collapsed){$details.Visibility=[Windows.Visibility]::Visible;$button.Content='收起'}else{$details.Visibility=[Windows.Visibility]::Collapsed;$button.Content='详情'}
})
$window.FindName('ResetPeaks').Add_Click({$script:peaks=@{};Update-Panel})
$script:timer=[Windows.Threading.DispatcherTimer]::new();$script:timer.Interval=[TimeSpan]::FromSeconds([Math]::Max(1,$config.refreshSeconds))
$script:timer.Add_Tick({Update-Panel});$window.Add_Closed({$script:timer.Stop();[PanelNative]::Close()})
if($ValidateOnly) {
    if((Get-HwSourceHint $true 0 0).Text -notlike '未收到传感器输出*'){throw 'Running process without telemetry must not imply active sampling.'}
    if((Get-HwSourceHint $true 9 0).Text -notlike '已收到输出*'){throw 'Unmatched live output must be distinguished from inactive sampling.'}
    if($null -ne (Get-HwSourceHint $true 9 5)){throw 'Live matching output must remain connected.'}
    if((Get-HwSourceHint $false 9 0).Text -notlike 'HWiNFO 未运行*'){throw 'Cached data must not imply a running source.'}
    $unitCases=@{'40 ℃'='C';'958 RPM'='RPM';'0 %'='%';'55.5 W'='W';'800 MHz'='MHz';'是'='bool';'否'='bool'}
    foreach($text in $unitCases.Keys){if((Get-ReadingUnit $text) -ne $unitCases[$text]){throw "Unit parse failed: $text"}}
    $cpuSpec=$config.metrics | Where-Object {$_.id -eq 'cpuFan'} | Select-Object -First 1
    $gpuSpec=$config.metrics | Where-Object {$_.id -eq 'gpuFan'} | Select-Object -First 1
    $fixture=@(
        [pscustomobject]@{Sensor='Maxsun MS-Terminator B760M D4 (Nuvoton NCT6796D)';Label='CPUFANIN0';Value=958;Unit='RPM'},
        [pscustomobject]@{Sensor='Maxsun MS-Terminator B760M D4 (Nuvoton NCT6796D)';Label='CPUFANIN0';Value=44;Unit='C'},
        [pscustomobject]@{Sensor='dGPU [#0]: NVIDIA GeForce RTX 4060';Label='GPU 风扇1';Value=0;Unit='RPM'},
        [pscustomobject]@{Sensor='dGPU [#0]: NVIDIA GeForce RTX 4060';Label='GPU 风扇1';Value=33;Unit='%'}
    )
    if((Resolve-Reading $cpuSpec $fixture).Value -ne 958){throw 'CPU fan binding is incorrect.'}
    $stopped=Resolve-Reading $gpuSpec $fixture
    if($null -eq $stopped -or $stopped.Value -ne 0){throw 'Valid zero RPM must be retained.'}
    if($null -ne (Resolve-Reading $cpuSpec @())){throw 'Missing data must not become zero.'}
    $tempFixture=@(
        [pscustomobject]@{Sensor='CPU [#0]: Intel Core i5-12490F: DTS';Label='CPU 封装';Value=36;Unit='C'},
        [pscustomobject]@{Sensor='dGPU [#0]: NVIDIA GeForce RTX 4060';Label='GPU 温度';Value=49.8;Unit='C'},
        [pscustomobject]@{Sensor='S.M.A.R.T.: Seagate ZP1000GV30012';Label='磁盘温度';Value=40;Unit='C'},
        [pscustomobject]@{Sensor='S.M.A.R.T.: ST4000VX015-3CU104';Label='磁盘温度';Value=40;Unit='C'},
        [pscustomobject]@{Sensor='S.M.A.R.T.: WDC WD4002FYYZ-01B7CB0';Label='磁盘温度';Value=43;Unit='C'}
    )
    foreach($spec in $config.sensors){if($null -eq (Resolve-Reading $spec $tempFixture)){throw "Temperature matching failed: $($spec.name)"}}
    $throttleSpec=$config.metrics | Where-Object {$_.id -eq 'cpuThrottle'} | Select-Object -First 1
    $throttleFixture=@(
        [pscustomobject]@{Sensor='Intel Core i5-12490F';Label='Core Thermal Throttling';Value=0;Unit='bool'},
        [pscustomobject]@{Sensor='Intel Core i5-12490F';Label='CPU Package Thermal Throttling';Value=1;Unit='bool'}
    )
    if((Resolve-Reading $throttleSpec $throttleFixture).Value -ne 1){throw 'Active thermal throttling must not be hidden by another false flag.'}
    Update-Panel;if($status.Text -like '读取失败*'){throw $status.Text}
    $actual=@(Get-HwReadings)
    foreach($spec in @($config.sensors)+@($config.metrics)){
        $reading=Resolve-Reading $spec $actual
        if($null -ne $reading){Write-Output ("LIVE: {0} = {1} {2}" -f $spec.name,$reading.Value,$reading.Unit)}
    }
    $os=[PanelNative]::ReadSystem();Write-Output ("SYSTEM: CPU {0:0.0} %, RAM {1:0.0}/{2:0.0} GB" -f $script:cpuLoad,$os.MemoryUsedGB,$os.MemoryTotalGB)
    $ng=[PanelNative]::ReadGpu()
    if($ng){Write-Output ("NVML: {0}, load {1} %, VRAM {2:0.0}/{3:0.0} GB, fan control {4} %" -f $ng.Name,$ng.Utilization,$ng.MemoryUsedGB,$ng.MemoryTotalGB,$ng.FanPercent)}
    [PanelNative]::Close();Write-Output 'PASS: WPF layout, units, actual readings, zero RPM and missing data.';exit
}
Update-Panel
if($PreviewPath){
    $window.Opacity=1;$visual=$window.Content;$visual.Width=$window.Width
    $visual.Measure([Windows.Size]::new($window.Width,2000));$visual.Arrange([Windows.Rect]::new(0,0,$window.Width,$visual.DesiredSize.Height));$visual.UpdateLayout()
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new([int]$visual.ActualWidth,[int]$visual.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual);$encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create($PreviewPath);try{$encoder.Save($stream)}finally{$stream.Dispose();[PanelNative]::Close()};exit
}
$script:timer.Start();[void]$window.ShowDialog()
