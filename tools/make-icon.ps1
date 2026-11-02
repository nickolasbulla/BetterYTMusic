# Gera o ícone do app (1024x1024). Uso: powershell -File tools/make-icon.ps1 -Out App/Assets.xcassets/AppIcon.appiconset/AppIcon.png
param([string]$Out)
Add-Type -AssemblyName System.Drawing

$S = 1024
$bmp = New-Object System.Drawing.Bitmap $S, $S, ([System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = 'AntiAlias'
$g.PixelOffsetMode = 'HighQuality'

# Fundo: verde do app, mais claro em cima.
$rect = New-Object System.Drawing.Rectangle 0, 0, $S, $S
$bg = New-Object System.Drawing.Drawing2D.LinearGradientBrush $rect, ([System.Drawing.Color]::FromArgb(0x2B, 0xE0, 0x6E)), ([System.Drawing.Color]::FromArgb(0x0B, 0x6E, 0x34)), 65.0
$g.FillRectangle($bg, $rect)

function New-Notes([float]$dx, [float]$dy) {
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $p.FillMode = 'Winding'
    $heads = @(@(372, 716), @(676, 636))
    foreach ($h in $heads) {
        $e = New-Object System.Drawing.Drawing2D.GraphicsPath
        $e.AddEllipse([float](-118), [float](-84), [float]236, [float]168)
        $m = New-Object System.Drawing.Drawing2D.Matrix
        $m.Translate([float]($h[0] + $dx), [float]($h[1] + $dy))
        $m.Rotate(-24)
        $e.Transform($m)
        $p.AddPath($e, $false)
    }
    # Hastes (lado direito de cada cabeça)
    $p.AddRectangle([System.Drawing.RectangleF]::new(([float](430 + $dx)), ([float](330 + $dy)), 50, 352))
    $p.AddRectangle([System.Drawing.RectangleF]::new(([float](734 + $dx)), ([float](260 + $dy)), 50, 342))
    # Barra que une as duas, inclinada
    $beam = [System.Drawing.PointF[]]@(
        [System.Drawing.PointF]::new(([float](430 + $dx)), ([float](300 + $dy))),
        [System.Drawing.PointF]::new(([float](784 + $dx)), ([float](220 + $dy))),
        [System.Drawing.PointF]::new(([float](784 + $dx)), ([float](335 + $dy))),
        [System.Drawing.PointF]::new(([float](430 + $dx)), ([float](415 + $dy)))
    )
    $p.AddPolygon($beam)
    return $p
}

# Sombra suave + notas brancas
$shadow = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(45, 0, 40, 15))
$g.FillPath($shadow, (New-Notes -24 22))
$g.FillPath([System.Drawing.Brushes]::White, (New-Notes -24 0))

$g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
