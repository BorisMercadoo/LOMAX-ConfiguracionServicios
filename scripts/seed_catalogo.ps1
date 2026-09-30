. "$PSScriptRoot\..\env.ps1"
Set-Location (Split-Path $PSScriptRoot)
Add-Type -AssemblyName System.Drawing
$API = "http://localhost:8080/api"
$enc = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force pruebas\catalogo | Out-Null
$colores = "SteelBlue","Tomato","SeaGreen","DarkOrange","MediumPurple","Teal","Crimson","Goldenrod","SlateGray","DeepPink"

function Publicados { $r = curl.exe -s "$API/productos" | ConvertFrom-Json; if ($null -eq $r) { 0 } else { @($r).Count } }
function Nueva-Imagen($ruta, $i, $w, $h, $txt) {
  $bmp = New-Object System.Drawing.Bitmap $w, $h
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.Clear([System.Drawing.Color]::FromName($colores[$i % $colores.Count]))
  $f = New-Object System.Drawing.Font("Arial", [single]($h / 8), [System.Drawing.FontStyle]::Bold)
  $g.DrawString($txt, $f, [System.Drawing.Brushes]::White, 30, [single]($h / 3))
  $f.Dispose(); $g.Dispose()
  $bmp.Save($ruta, [System.Drawing.Imaging.ImageFormat]::Jpeg); $bmp.Dispose()
}

$hay = Publicados; $faltan = 20 - $hay; $creados = 0
Write-Host "Publicados: $hay | faltan: $faltan"
for ($i = 1; $i -le 60 -and $creados -lt $faltan; $i++) {
  $cod = "CAT-{0:000}" -f $i
  if ($i % 2) { $cat = 1; $nom = "Teclado modelo $i"; $attr = '{"conexion":"USB","distribucion":"QWERTY"}' }
  else { $cat = 2; $nom = "Monitor modelo $i"; $attr = '{"pulgadas":24,"resolucion":"1920x1080"}' }
  $json = '{"codigo":"' + $cod + '","nombre":"' + $nom + '","descripcion":"Producto de catalogo ' + $i + '","precio":' + (10 + $i * 7) + '.5,"categoria_id":' + $cat + ',"atributos":' + $attr + '}'
  [IO.File]::WriteAllText("$PWD\pruebas\catalogo\p.json", $json, $enc)
  $out = @(curl.exe -s -w "`n%{http_code}" -X POST -H "Content-Type: application/json" --data-binary "@pruebas/catalogo/p.json" "$API/productos")
  if ($out[-1] -ne "201") { Write-Host "$cod -> HTTP $($out[-1]) (omitido)"; continue }
  $id = ($out[0] | ConvertFrom-Json).producto_id
  $ruta = "$PWD\pruebas\catalogo\$cod.jpg"
  if ($i % 3 -eq 0) { Nueva-Imagen $ruta $i 800 1000 $cod } else { Nueva-Imagen $ruta $i 1200 800 $cod }
  $r = @(curl.exe -s -w "`n%{http_code}" -X POST -F "imagen=@$ruta" "$API/productos/$id/imagen")
  Write-Host "$cod producto_id=$id imagen -> HTTP $($r[-1])"
  if ($r[-1] -eq "200") { $creados++ }
}
Write-Host "Publicados ahora: $(Publicados)"