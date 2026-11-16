$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

function New-RadarBitmap([int]$Size) {
  $bmp = [System.Drawing.Bitmap]::new($Size, $Size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
  $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.Clear([System.Drawing.Color]::Transparent)

  $pad = [float]([math]::Max(1, $Size * 0.06))
  $rectSize = [float]($Size - 2 * $pad)
  $radius = [float]($Size * 0.24)

  $path = [System.Drawing.Drawing2D.GraphicsPath]::new()
  $d = $radius * 2
  $path.AddArc($pad, $pad, $d, $d, 180, 90)
  $path.AddArc($pad + $rectSize - $d, $pad, $d, $d, 270, 90)
  $path.AddArc($pad + $rectSize - $d, $pad + $rectSize - $d, $d, $d, 0, 90)
  $path.AddArc($pad, $pad + $rectSize - $d, $d, $d, 90, 90)
  $path.CloseFigure()

  $bgBrush = [System.Drawing.Drawing2D.LinearGradientBrush]::new(
    [System.Drawing.PointF]::new(0, 0),
    [System.Drawing.PointF]::new($Size, $Size),
    [System.Drawing.Color]::FromArgb(255, 20, 26, 40),
    [System.Drawing.Color]::FromArgb(255, 13, 18, 28)
  )
  $g.FillPath($bgBrush, $path)

  $borderPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(255, 56, 189, 248), [math]::Max(1.0, $Size * 0.05))
  $g.DrawPath($borderPen, $path)

  $cx = [float]($Size * 0.5)
  $cy = [float]($Size * 0.52)
  $rOuter = [float]($Size * 0.31)
  $rInner = [float]($Size * 0.17)

  $ringPen1 = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(190, 16, 232, 138), [math]::Max(1.0, $Size * 0.055))
  $ringPen2 = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(140, 56, 189, 248), [math]::Max(1.0, $Size * 0.045))
  $g.DrawEllipse($ringPen1, $cx - $rOuter, $cy - $rOuter, $rOuter * 2, $rOuter * 2)
  $g.DrawEllipse($ringPen2, $cx - $rInner, $cy - $rInner, $rInner * 2, $rInner * 2)

  $beamPen = [System.Drawing.Pen]::new([System.Drawing.Color]::FromArgb(255, 16, 232, 138), [math]::Max(1.2, $Size * 0.07))
  $beamPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $beamPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $g.DrawLine($beamPen, $cx, $cy, $cx + $rOuter * 0.72, $cy - $rOuter * 0.72)

  $dotR = [float]([math]::Max(1.5, $Size * 0.09))
  $blipBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 255, 77, 109))
  $g.FillEllipse($blipBrush, ($cx + $rOuter * 0.52) - $dotR, ($cy - $rOuter * 0.52) - $dotR, $dotR * 2, $dotR * 2)

  $centerR = [float]([math]::Max(1.2, $Size * 0.065))
  $centerBrush = [System.Drawing.SolidBrush]::new([System.Drawing.Color]::FromArgb(255, 248, 250, 252))
  $g.FillEllipse($centerBrush, $cx - $centerR, $cy - $centerR, $centerR * 2, $centerR * 2)

  $centerBrush.Dispose()
  $blipBrush.Dispose()
  $beamPen.Dispose()
  $ringPen2.Dispose()
  $ringPen1.Dispose()
  $borderPen.Dispose()
  $bgBrush.Dispose()
  $path.Dispose()
  $g.Dispose()
  return $bmp
}

$sizes = @(16, 32, 48, 128)
$pngPayloads = [System.Collections.Generic.List[byte[]]]::new()
foreach ($sz in $sizes) {
  $bmp = New-RadarBitmap $sz
  $ms = [System.IO.MemoryStream]::new()
  $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
  $pngPayloads.Add($ms.ToArray())
  $ms.Dispose()
  $bmp.Dispose()
}

$icoPath = Join-Path (Split-Path $PSScriptRoot -Parent) "pr-radar.ico"
$fs = [System.IO.File]::Create($icoPath)
$bw = [System.IO.BinaryWriter]::new($fs)
try {
  # ICONDIR header
  $bw.Write([uint16]0)
  $bw.Write([uint16]1)
  $bw.Write([uint16]$sizes.Count)

  $offset = 6 + (16 * $sizes.Count)
  for ($i = 0; $i -lt $sizes.Count; $i++) {
    $sz = $sizes[$i]
    $bytes = $pngPayloads[$i]
    $dimByte = if ($sz -ge 256) { [byte]0 } else { [byte]$sz }
    $bw.Write($dimByte)
    $bw.Write($dimByte)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]$bytes.Length)
    $bw.Write([uint32]$offset)
    $offset += $bytes.Length
  }

  for ($i = 0; $i -lt $sizes.Count; $i++) {
    $bw.Write($pngPayloads[$i])
  }
} finally {
  $bw.Dispose()
  $fs.Dispose()
}
Write-Output "ICO_CREATED: $icoPath"
