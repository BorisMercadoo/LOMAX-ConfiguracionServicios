. "$PSScriptRoot\..\env.ps1"
$root = Split-Path $PSScriptRoot
Push-Location $root
$enc = New-Object System.Text.UTF8Encoding($false)

# RDS: crear solo si no existe
aws rds describe-db-instances --db-instance-identifier lomax-db 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  aws rds create-db-instance --db-instance-identifier lomax-db --engine postgres --db-instance-class db.t3.micro --allocated-storage 20 --master-username admin --master-user-password admin12345 --db-name lomax | Out-Null
}
$DB = ""
for ($i=0; $i -lt 30 -and -not $DB; $i++) { $DB = docker ps --filter "name=floci-rds" --format "{{.Names}}"; if (-not $DB) { Start-Sleep 2 } }
Start-Sleep 5

# Esquema y carga (idempotentes)
docker cp sql\01_schema.sql "${DB}:/tmp/01_schema.sql"
docker cp sql\02_seed.sql   "${DB}:/tmp/02_seed.sql"
docker exec $DB psql -U admin -d lomax -f /tmp/01_schema.sql
docker exec $DB psql -U admin -d lomax -f /tmp/02_seed.sql

# DynamoDB: crear solo si no existe
aws dynamodb describe-table --table-name productos_atributos 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  aws dynamodb create-table --table-name productos_atributos --attribute-definitions AttributeName=producto_id,AttributeType=S --key-schema AttributeName=producto_id,KeyType=HASH --billing-mode PAY_PER_REQUEST | Out-Null
}

function Get-Id($codigo) { (docker exec $DB psql -U admin -d lomax -t -A -c "SELECT producto_id FROM productos WHERE codigo='$codigo';").Trim() }
New-Item -ItemType Directory -Force dynamo | Out-Null
$id1 = Get-Id "TEC-001"
$id2 = Get-Id "PAN-001"
$j1 = '{"producto_id":{"S":"' + $id1 + '"},"atributos":{"M":{"conexion":{"S":"USB"},"distribucion":{"S":"QWERTY"}}},"estado_procesamiento":{"S":"PENDIENTE"}}'
$j2 = '{"producto_id":{"S":"' + $id2 + '"},"atributos":{"M":{"pulgadas":{"N":"27"},"resolucion":{"S":"1920x1080"}}},"estado_procesamiento":{"S":"PENDIENTE"}}'
[IO.File]::WriteAllText("$PWD\dynamo\item_$id1.json", $j1, $enc)
[IO.File]::WriteAllText("$PWD\dynamo\item_$id2.json", $j2, $enc)
# La condicion evita sobrescribir un item que ya existe
aws dynamodb put-item --table-name productos_atributos --item file://dynamo/item_$id1.json --condition-expression "attribute_not_exists(producto_id)" 2>$null
aws dynamodb put-item --table-name productos_atributos --item file://dynamo/item_$id2.json --condition-expression "attribute_not_exists(producto_id)" 2>$null

Write-Host "Etapa 2 lista: RDS + DynamoDB" -ForegroundColor Green
Pop-Location