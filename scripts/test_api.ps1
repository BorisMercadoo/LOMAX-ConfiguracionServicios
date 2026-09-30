. "$PSScriptRoot\..\env.ps1"
Set-Location (Split-Path $PSScriptRoot)
$API = "http://localhost:3000"
$DB = docker ps --filter "name=floci-rds" --format "{{.Names}}"
$enc = New-Object System.Text.UTF8Encoding($false)
function T($t) { Write-Host ""; Write-Host "=== $t ===" }
function Api { curl.exe -s -w "`n-> HTTP %{http_code}" @args; Write-Host "" }
function Directo($id) {
  docker exec $DB psql -U admin -d lomax -c "SELECT producto_id, codigo, estado FROM productos WHERE producto_id=$id;"
  aws dynamodb get-item --table-name productos_atributos --key "{\`"producto_id\`":{\`"S\`":\`"$id\`"}}" --query "Item.{estado:estado_procesamiento.S,original:imagen_original_key.S,miniatura:miniatura_key.S,error:error_procesamiento.S}" --output json
  aws s3 ls s3://lomax-miniaturas/miniaturas/
}

# Archivos de prueba
$codigo = "API-" + (Get-Date -Format "HHmmss")
[IO.File]::WriteAllText("$PWD\pruebas\t_ok.json", ('{"codigo":"' + $codigo + '","nombre":"Producto de prueba","descripcion":"Creado por test_api","precio":19.99,"categoria_id":1,"atributos":{"conexion":"USB","distribucion":"QWERTY"}}'), $enc)
[IO.File]::WriteAllText("$PWD\pruebas\t_neg.json", '{"codigo":"X-1","nombre":"Neg","descripcion":"d","precio":-5,"categoria_id":1,"atributos":{"a":"b"}}', $enc)
[IO.File]::WriteAllText("$PWD\pruebas\t_cat.json", '{"codigo":"X-2","nombre":"SinCat","descripcion":"d","precio":5,"categoria_id":999,"atributos":{"a":"b"}}', $enc)
$b = [IO.File]::ReadAllBytes("$PWD\pruebas\original_1200x800.jpg")
[IO.File]::WriteAllBytes("$PWD\pruebas\corrupto.jpg", [byte[]]($b[0..199]))
$g = New-Object byte[] (6MB); $g[0]=0xFF; $g[1]=0xD8; $g[2]=0xFF
[IO.File]::WriteAllBytes("$PWD\pruebas\grande.jpg", $g)

T "GET /categorias (200)"
Api "$API/categorias"

T "POST /productos precio negativo (400)"
Api -X POST -H "Content-Type: application/json" --data-binary "@pruebas/t_neg.json" "$API/productos"

T "POST /productos categoria inexistente (400)"
Api -X POST -H "Content-Type: application/json" --data-binary "@pruebas/t_cat.json" "$API/productos"

T "POST /productos valido (201)"
$out = @(curl.exe -s -w "`n%{http_code}" -X POST -H "Content-Type: application/json" --data-binary "@pruebas/t_ok.json" "$API/productos")
Write-Host "HTTP $($out[-1]) $($out[0])"
$id = ($out[0] | ConvertFrom-Json).producto_id
Write-Host "producto_id = $id"

T "POST /productos repetido (409 codigo duplicado)"
Api -X POST -H "Content-Type: application/json" --data-binary "@pruebas/t_ok.json" "$API/productos"

T "GET /productos/$id (200, PENDIENTE)"
Api "$API/productos/$id"

T "GET /productos/999999 (404)"
Api "$API/productos/999999"

T "POST /productos/$id/reprocesar sin original (409)"
Api -X POST "$API/productos/$id/reprocesar"

T "POST /productos/$id/imagen archivo de texto (415)"
Api -X POST -F "imagen=@pruebas/invalido.jpg" "$API/productos/$id/imagen"

T "POST /productos/$id/imagen JPEG corrupto (Lambda ERROR, producto sigue PENDIENTE)"
Api -X POST -F "imagen=@pruebas/corrupto.jpg" "$API/productos/$id/imagen"
Directo $id

T "GET /productos no debe listar el producto $id (solo publicados)"
(curl.exe -s "$API/productos" | ConvertFrom-Json) | Select-Object producto_id, codigo, estado | Format-Table | Out-String

T "POST /productos/$id/imagen archivo > 5 MB (413)"
Api -X POST -F "imagen=@pruebas/grande.jpg" "$API/productos/$id/imagen"

T "POST /productos/$id/imagen JPEG valido (200, PUBLICADO) - completa el mismo registro"
Api -X POST -F "imagen=@pruebas/original_1200x800.jpg" "$API/productos/$id/imagen"
Directo $id

T "POST /productos/$id/reprocesar repetido (200, sin objetos extra)"
Api -X POST "$API/productos/$id/reprocesar"
aws s3 ls s3://lomax-miniaturas/miniaturas/

T "GET /productos/$id/imagen (200 image/jpeg)"
curl.exe -s -o "evidencias\E4_api_mini.jpg" -w "HTTP %{http_code} Content-Type: %{content_type}" "$API/productos/$id/imagen"
Write-Host ""
aws s3api get-object --bucket lomax-miniaturas --key "miniaturas/$id.jpg" "evidencias\E4_s3_mini.jpg" | Out-Null
$h1 = (Get-FileHash "evidencias\E4_api_mini.jpg").Hash
$h2 = (Get-FileHash "evidencias\E4_s3_mini.jpg").Hash
if ($h1 -eq $h2) { Write-Host "Hash API = Hash S3 -> IGUALES ($h1)" } else { Write-Host "DIFERENTES: API=$h1 S3=$h2" }

T "GET /productos/999999/imagen (404)"
Api "$API/productos/999999/imagen"

T "Publicar productos de la etapa 3 (1, 2, 5) con /reprocesar"
foreach ($n in 1,2,5) { Write-Host "producto $n"; Api -X POST "$API/productos/$n/reprocesar" }

T "Catalogo final (solo PUBLICADOS)"
(curl.exe -s "$API/productos" | ConvertFrom-Json) | Select-Object producto_id, codigo, categoria, estado | Format-Table | Out-String