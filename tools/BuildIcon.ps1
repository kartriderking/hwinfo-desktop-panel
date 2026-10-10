param([string]$PreviewPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationCore,WindowsBase
$root=Split-Path -Parent $PSScriptRoot
[xml]$svg=[IO.File]::ReadAllText((Join-Path $root 'assets\panel.svg'))
$frames=@()
foreach($size in @(256,128,64,48,32,24,16)) {
    $visual=[Windows.Media.DrawingVisual]::new();$context=$visual.RenderOpen()
    try {
        $context.PushTransform([Windows.Media.ScaleTransform]::new($size/64.0,$size/64.0))
        foreach($node in $svg.DocumentElement.ChildNodes) {
            $fill=$null;$pen=$null
            if($node.HasAttribute('fill') -and $node.GetAttribute('fill') -ne 'none'){$fill=[Windows.Media.BrushConverter]::new().ConvertFromString($node.GetAttribute('fill'))}
            if($node.HasAttribute('stroke')) {
                $pen=[Windows.Media.Pen]::new([Windows.Media.BrushConverter]::new().ConvertFromString($node.GetAttribute('stroke')),[double]$node.GetAttribute('stroke-width'))
                if($node.GetAttribute('stroke-linecap') -eq 'round'){$pen.StartLineCap=[Windows.Media.PenLineCap]::Round;$pen.EndLineCap=[Windows.Media.PenLineCap]::Round}
                if($node.GetAttribute('stroke-linejoin') -eq 'round'){$pen.LineJoin=[Windows.Media.PenLineJoin]::Round}
            }
            switch($node.LocalName) {
                'rect' {$context.DrawRoundedRectangle($fill,$pen,[Windows.Rect]::new([double]$node.x,[double]$node.y,[double]$node.width,[double]$node.height),[double]$node.rx,[double]$node.rx)}
                'path' {$context.DrawGeometry($fill,$pen,[Windows.Media.Geometry]::Parse($node.d))}
                'circle' {$context.DrawEllipse($fill,$pen,[Windows.Point]::new([double]$node.cx,[double]$node.cy),[double]$node.r,[double]$node.r)}
                default {throw "Unsupported SVG element: $($node.LocalName)"}
            }
        }
        $context.Pop()
    } finally {$context.Close()}
    $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new($size,$size,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($visual)
    $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new();$encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.MemoryStream]::new();try{$encoder.Save($stream);$frames+=,[pscustomobject]@{Size=$size;Bytes=$stream.ToArray()}}finally{$stream.Dispose()}
}
$iconStream=[IO.File]::Open((Join-Path $root 'assets\panel.ico'),[IO.FileMode]::Create)
$writer=[IO.BinaryWriter]::new($iconStream)
try {
    $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]$frames.Count)
    $offset=6+16*$frames.Count
    foreach($frame in $frames){$dimension=$frame.Size;if($dimension -eq 256){$dimension=0};$writer.Write([byte]$dimension);$writer.Write([byte]$dimension);$writer.Write([byte]0);$writer.Write([byte]0);$writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$frame.Bytes.Length);$writer.Write([uint32]$offset);$offset+=$frame.Bytes.Length}
    foreach($frame in $frames){$writer.Write([byte[]]$frame.Bytes)}
} finally {$writer.Dispose();$iconStream.Dispose()}
if($PreviewPath){[IO.File]::WriteAllBytes($PreviewPath,[byte[]]$frames[0].Bytes)}
Write-Output 'Built panel.ico at 16, 24, 32, 48, 64, 128 and 256 pixels.'
