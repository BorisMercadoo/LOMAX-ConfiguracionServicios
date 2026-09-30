. .\env.ps1
$DB = docker ps --filter "name=floci-rds" --format "{{.Names}}"
function sql($q) { docker exec $DB psql -U admin -d lomax -c $q 2>&1 }

Write-Host "`n== RDS: productos ==" -ForegroundColor Cyan
sql "SELECT producto_id, codigo, nombre, precio, estado FROM productos ORDER BY producto_id;"

Write-Host "`n== 1. Insercion valida ==" -ForegroundColor Cyan
sql "INSERT INTO productos (codigo,nombre,descripcion,precio,categoria_id) VALUES ('DEMO-001','Demo','desc',10,1) RETURNING producto_id;"

Write-Host "`n== 2. Codigo duplicado (debe fallar) ==" -ForegroundColor Cyan
sql "INSERT INTO productos (codigo,nombre,descripcion,precio,categoria_id) VALUES ('TEC-001','Otro','desc',10,1);"

Write-Host "`n== 3. Precio negativo (debe fallar) ==" -ForegroundColor Cyan
sql "INSERT INTO productos (codigo,nombre,descripcion,precio,categoria_id) VALUES ('DEMO-002','Neg','desc',-5,1);"

Write-Host "`n== 4. Categoria inexistente (debe fallar) ==" -ForegroundColor Cyan
sql "INSERT INTO productos (codigo,nombre,descripcion,precio,categoria_id) VALUES ('DEMO-003','SinCat','desc',10,999);"

Write-Host "`n== Sin registros parciales (solo DEMO-001 nuevo) ==" -ForegroundColor Cyan
sql "SELECT codigo FROM productos WHERE codigo LIKE 'DEMO-%';"
sql "DELETE FROM productos WHERE codigo LIKE 'DEMO-%';"

Write-Host "`n== DynamoDB: get-item por producto_id ==" -ForegroundColor Cyan
1,2,5 | ForEach-Object { aws dynamodb get-item --table-name productos_atributos --key "{\`"producto_id\`":{\`"S\`":\`"$_\`"}}" }