LOMAX: catálogo de productos sobre AWS emulado con Floci

Sistema de registro y consulta de productos para Lomax SA, construido con Docker, Kubernetes y servicios AWS (RDS, DynamoDB, S3, Lambda, ECR, EKS) emulados localmente con Floci.

Alcance: registrar productos, mostrar el catálogo y consultar el detalle de un producto.

Repositorio: https://github.com/BorisMercadoo/LOMAX-ConfiguracionServicios

1. Equipo y roles (P10)

Integrante	Cuenta de GitHub	Etapas 
Boris Mercado	BorisMercadoo	3	
Ludwin Gutierrez Ellud 3


2. Arquitectura

Diagrama oficial (Etapa 1, entregable P2): [COMPLETAR ruta, por ejemplo docs/diagrama-arquitectura.png]

Resumen en texto:

Usuario ──HTTP──> proxy (nginx) ──/──────> frontend (nginx + HTML/JS)
                       │
                       └──/api/──> API (Node.js + Express)
                                      │
                 ┌────────────────────┼──────────────────────────┐
                 │                    │                          │
            RDS PostgreSQL        DynamoDB                   S3 (2 buckets)
        (categorías, productos)  (atributos, imagen)    originales / miniaturas
                                                                 ▲
                                      Lambda (Python + Pillow) ──┘
                                      invocada de forma síncrona por la API

Todos los servicios AWS los atiende el contenedor floci (puerto 4566). ECR y EKS se apoyan en un registro registry:2 y en un clúster k3s, ambos como contenedores que Floci crea.
<img width="1042" height="695" alt="image" src="https://github.com/user-attachments/assets/237a3194-daae-41da-82a0-f8f4c7f1f873" />

2.1 Componentes, puertos y ubicación
Componente	Recurso	Endpoint / puerto	Ubicación
Emulador AWS	contenedor floci (floci/floci:latest, v2.1.0)	4566 (HTTP)	red Docker lomax_default (IP 172.19.0.2)
RDS	instancia lomax-db, PostgreSQL 16	floci:7001 (Floci lo reenvía al 5432 del contenedor floci-rds-db-*)	volumen Docker propio; el puerto 7001 no se publica al host
DynamoDB	tabla productos_atributos (clave producto_id, tipo S)	4566	almacenamiento hybrid en ./data
S3	buckets lomax-originales y lomax-miniaturas	4566	almacenamiento hybrid en ./data
Lambda	función lomax-miniatura (Python 3.12, Pillow, 256 MB, 30 s)	invocación síncrona por 4566	contenedor efímero creado por Floci
ECR	repositorios lomax-backend y lomax-frontend	000000000000.dkr.ecr.us-east-1.localhost:4566/<repo>	registro registry:2 (contenedor floci-ecr-registry, 127.0.0.1:5100)
EKS	clúster lomax (k3s)	API de Kubernetes en https://localhost:6500	contenedor floci-eks-lomax, red lomax_default
Backend	API Node 20 + Express	3000	Pods backend (3 réplicas) / contenedor lomax-api
Frontend	nginx + HTML/JS	80 interno	Pod frontend / contenedor lomax-frontend
Reverse proxy	nginx	8080 (Compose); Service proxy:80 (EKS, expuesto con port-forward en 8090)	Pod proxy / contenedor lomax-proxy

Protocolos: HTTP entre usuario, proxy, frontend y API; API de AWS sobre HTTP (JSON/XML) hacia Floci; protocolo PostgreSQL hacia RDS; OCI Distribution v2 (HTTP) hacia el registro.

2.2 Flujo de un producto
POST /productos: la API valida, inserta el producto en RDS como PENDIENTE y guarda sus atributos en DynamoDB (mismo producto_id).
POST /productos/{id}/imagen: la API valida la firma del archivo (JPEG o PNG, máximo 5 MB), guarda el original en lomax-originales e invoca Lambda de forma síncrona.
Lambda valida la imagen, genera una miniatura de hasta 300 × 300 (conserva proporción), la guarda en lomax-miniaturas con la clave determinista miniaturas/{producto_id}.jpg y actualiza DynamoDB con LISTA o ERROR.
La API cambia el producto a PUBLICADO solo si confirma atributos, estado LISTA y que la miniatura existe en S3. Si algo falla, el producto sigue PENDIENTE y se puede reintentar con POST /productos/{id}/reprocesar.
El catálogo (GET /productos) combina RDS y DynamoDB y lista solo los publicados. Las imágenes se sirven a través de la API (GET /productos/{id}/imagen).
2.3 Modelo de datos

RDS (PostgreSQL): sql/01_schema.sql

categorias(categoria_id PK, nombre UNIQUE NOT NULL)
productos(producto_id PK, codigo UNIQUE NOT NULL, nombre, descripcion, precio NUMERIC(12,2) CHECK (precio >= 0), categoria_id FK, fecha, estado CHECK IN ('PENDIENTE','PUBLICADO'))

DynamoDB: tabla productos_atributos, clave producto_id (S). Campos: atributos (mapa variable según el tipo de producto), estado_procesamiento (PENDIENTE, LISTA, ERROR), imagen_original_key, miniatura_key, error_procesamiento. No hay clave foránea entre RDS y DynamoDB: la API verifica la correspondencia.

3. Estructura del repositorio
.
├── README.md
├── .env.example              # configuración de ejemplo de la API
├── env.ps1                   # variables para usar el AWS CLI contra Floci
├── docker-compose.yml        # floci + api + frontend + proxy
├── api/                      # backend (Dockerfile, package.json, server.js)
├── frontend/                 # frontend (Dockerfile, index.html)
├── proxy/nginx.conf          # reverse proxy
├── lambda/                   # handler.py, build.sh, env.json
├── sql/                      # esquema, carga inicial y pruebas de restricciones
├── dynamo/                   # items de ejemplo de DynamoDB
├── k8s/lomax.yaml            # manifiestos de Kubernetes (EKS)
├── scripts/                  # scripts reproducibles y de demostración
├── pruebas/                  # archivos de prueba (imágenes, JSON)
└── evidencias/               # E1 a E7, una carpeta por etapa

Scripts en scripts/:

Script	Función
setup_etapa2.ps1	Crea RDS y la tabla DynamoDB y carga datos. Repetible: no duplica ni sobrescribe.
demo_e2.ps1	Demuestra en vivo las pruebas de restricciones y los get-item.
test_api.ps1	Ejecuta todos los endpoints con casos válidos e inválidos y verifica los servicios directamente.
seed_catalogo.ps1	Publica productos de ejemplo hasta completar 20.
organizar_evidencias.ps1	Ordena evidencias/ en carpetas E1 a E7.
4. Requisitos previos

Probado en Windows con: Docker Desktop, AWS CLI v2, kubectl, Git y PowerShell 5.1.

Entrada en el archivo hosts (solo Windows). Windows no resuelve *.localhost; sin esto falla docker login contra ECR. En PowerShell como administrador:
powershell
Add-Content C:\Windows\System32\drivers\etc\hosts "127.0.0.1 000000000000.dkr.ecr.us-east-1.localhost"
ipconfig /flushdns
No ejecutar docker compose down -v ni docker volume prune: borran datos de RDS.
5. Configuración de ejemplo
Archivo	Uso
.env.example	Variables de entorno de la API (copiar a .env si se usa fuera de Compose).
env.ps1	Endpoint y credenciales de prueba para el AWS CLI (. .\env.ps1 en cada terminal nueva).
docker-compose.yml	Definición de floci (modo hybrid), api, frontend y proxy.
k8s/lomax.yaml	ConfigMap, Secret, Deployments y Services del despliegue en EKS.
proxy/nginx.conf	Enrutamiento: /api/ a la API y el resto al frontend.
lambda/env.json	Variables de entorno de la función Lambda.

Las credenciales del repositorio (test/test, admin/admin12345) son solo de desarrollo local con el emulador. En AWS real irían en Secrets Manager o equivalente y no en el repositorio.

6. Puesta en marcha, etapa por etapa

Cada bloque se ejecuta desde la raíz del repositorio. Después de clonar:

powershell
git clone https://github.com/BorisMercadoo/LOMAX-ConfiguracionServicios.git
cd LOMAX-ConfiguracionServicios
. .\env.ps1
docker compose up -d --build

Esto levanta floci, api, frontend y proxy. La aplicación queda en http://localhost:8080.

Etapa 1: arquitectura

Diagrama en la ruta indicada arriba. La verificación E1 contrasta el diagrama con los recursos desplegados:

powershell
docker ps
kubectl get all -n lomax
Etapa 2: RDS y DynamoDB
powershell
powershell -ExecutionPolicy Bypass -File scripts\setup_etapa2.ps1
powershell -ExecutionPolicy Bypass -File scripts\demo_e2.ps1

El primero crea y carga (repetirlo no duplica). El segundo prueba inserción válida, código duplicado, precio negativo y categoría inexistente (los tres últimos deben fallar sin dejar registros parciales) y muestra los get-item de DynamoDB.

Verificación tras reiniciar sin borrar volúmenes:

powershell
docker restart floci
# volver a ejecutar las consultas y comparar con las salidas guardadas en evidencias\E2
Etapa 3: S3 y Lambda
powershell
aws s3 mb s3://lomax-originales
aws s3 mb s3://lomax-miniaturas

# Empaquetar Pillow para Linux con Docker (no requiere Python en Windows)
docker run --rm -v "${PWD}\lambda:/work" python:3.12-slim sh /work/build.sh

aws lambda create-function --function-name lomax-miniatura --runtime python3.12 --handler handler.handler --role arn:aws:iam::000000000000:role/lambda-role --zip-file fileb://lambda/function.zip --timeout 30 --memory-size 256 --environment file://lambda/env.json

Prueba con la CLI:

powershell
aws s3 cp pruebas\original_1200x800.jpg s3://lomax-originales/originales/1.jpg
aws lambda invoke --function-name lomax-miniatura --cli-binary-format raw-in-base64-out --payload file://pruebas/evento_1.json salida.json
Get-Content salida.json
aws s3 ls s3://lomax-miniaturas/miniaturas/

Un original de 1200 × 800 debe producir una miniatura de 300 × 200. lambda invoke devuelve StatusCode: 200 incluso con una imagen inválida (la función atrapa el error y responde ok:false); el resultado funcional se lee en el archivo de salida y en el estado de DynamoDB.

Etapa 4: API

La API corre en el contenedor lomax-api (puerto 3000, también accesible por el proxy en http://localhost:8080/api).

powershell
powershell -ExecutionPolicy Bypass -File scripts\test_api.ps1

Ejecuta todos los endpoints, verifica directamente RDS, DynamoDB y S3 y compara el hash de la miniatura del endpoint con la descargada de S3.

Etapa 5: frontend

Abrir http://localhost:8080. Tres vistas: registrar producto (#/registrar), catálogo (#/catalogo) y detalle (#/producto/{id}). Para llegar a 20 productos publicados:

powershell
powershell -ExecutionPolicy Bypass -File scripts\seed_catalogo.ps1
Etapa 6: ECR
powershell
$SHA = git rev-parse --short HEAD
$REG = "000000000000.dkr.ecr.us-east-1.localhost:4566"

aws ecr create-repository --repository-name lomax-backend
aws ecr create-repository --repository-name lomax-frontend
aws ecr get-login-password | docker login --username AWS --password-stdin $REG

docker build -t "$REG/lomax-backend:$SHA" api
docker build -t "$REG/lomax-frontend:$SHA" frontend
docker push "$REG/lomax-backend:$SHA"
docker push "$REG/lomax-frontend:$SHA"

aws ecr list-images --repository-name lomax-backend
aws ecr describe-images --repository-name lomax-backend

Las imágenes publicadas están etiquetadas con 5cb1d38. Ese commit solo añadió archivos de prueba: el código de api/ y frontend/ no cambió desde entonces. Se puede comprobar con:

powershell
git diff 5cb1d38 HEAD --stat -- api frontend

(la salida debe estar vacía).

Autenticación: aws ecr get-login-password entrega el token que usa docker login. Dirección del registro: 000000000000.dkr.ecr.us-east-1.localhost:4566. Conectividad desde Docker: *.localhost resuelve a 127.0.0.1 (en Windows requiere la entrada del hosts). Conectividad desde Kubernetes: al crear el clúster, Floci escribe un registries.yaml en k3s (/etc/rancher/k3s/registries.yaml) que redirige ese nombre a http://172.19.0.2:4566.

Etapa 7: EKS
powershell
aws eks create-cluster --name lomax --role-arn arn:aws:iam::000000000000:role/eks-role --resources-vpc-config subnetIds=subnet-default-us-east-1-a,subnet-default-us-east-1-b
aws eks describe-cluster --name lomax --query "cluster.status"     # esperar ACTIVE

# kubeconfig: el clúster es un k3s con certificado de cliente (el token IAM de update-kubeconfig no autentica)
$f = "$HOME\.kube\lomax-k3s.yaml"
docker exec floci-eks-lomax cat /etc/rancher/k3s/k3s.yaml | Out-File -Encoding ascii $f
(Get-Content $f) -replace 'https://127\.0\.0\.1:6443','https://127.0.0.1:6500' | Set-Content -Encoding ascii $f
$env:KUBECONFIG = $f
kubectl get nodes

kubectl create namespace lomax
kubectl create configmap proxy-conf -n lomax --from-file=default.conf=proxy/nginx.conf
kubectl apply -f k8s/lomax.yaml
kubectl rollout status deployment/backend -n lomax

# Entrada de usuarios (la ventana debe quedar abierta)
kubectl port-forward -n lomax svc/proxy 8090:80

Aplicación en EKS: http://localhost:8090. Comprobaciones de E7:

powershell
# Pods y las imágenes de ECR que ejecutan (tag y digest)
kubectl get pods -n lomax -o jsonpath="{range .items[*]}{.metadata.name}{'  '}{.spec.containers[0].image}{'  '}{.status.containerStatuses[0].imageID}{'\n'}{end}"

# Escalar de 1 a 3 réplicas
kubectl scale deployment/backend -n lomax --replicas=3

# Reparto: cada respuesta trae el nombre del Pod que la atendió
1..60 | ForEach-Object { (curl.exe -s http://localhost:8090/api/health | ConvertFrom-Json).instancia } | Group-Object

# Autorrecuperación: UID antes y después de borrar un Pod
$pod = (kubectl get pods -n lomax -l app=backend -o jsonpath="{.items[0].metadata.name}")
kubectl get pod $pod -n lomax -o jsonpath="{.metadata.uid}"
kubectl delete pod $pod -n lomax
kubectl get pods -n lomax -l app=backend -o custom-columns="NOMBRE:.metadata.name,UID:.metadata.uid"

# Persistencia: recrear todos los Pods y repetir consultas
kubectl rollout restart deployment/backend deployment/frontend deployment/proxy -n lomax

Nota: k8s/lomax.yaml declara replicas: 1 para el backend (estado inicial de E7). Volver a ejecutar kubectl apply -f k8s/lomax.yaml devuelve el backend a 1 réplica; hay que escalar de nuevo.

7. API: endpoints y códigos

Las respuestas de error usan el formato { "error": "...", "paso_fallido": "rds|dynamodb|s3|lambda", "campos": [...], "detalle": "..." }. Toda respuesta incluye la cabecera X-Instance con el nombre del Pod o contenedor que la atendió.

Endpoint	Códigos
GET /categorias	200 lista de categorías (RDS)
POST /productos	201 (producto_id, PENDIENTE); 400 datos inválidos, precio negativo o categoría inexistente; 409 código duplicado; 503 servicio caído (indica paso_fallido)
POST /productos/{id}/imagen	200 PUBLICADO; 400 falta la imagen; 404 producto inexistente; 409 sin atributos registrados; 413 archivo mayor a 5 MB; 415 no es JPEG/PNG o la imagen no es válida (Lambda ERROR); 502 fallo de Lambda; 503 fallo de RDS, DynamoDB o S3
POST /productos/{id}/reprocesar	200 publica si completa; 409 si no existe el original; 404 producto inexistente; 415 imagen inválida
GET /productos	200 solo productos PUBLICADO, con atributos y referencia de miniatura
GET /productos/{id}	200 detalle y estado (también de pendientes); 404 si no existe
GET /productos/{id}/imagen	200 bytes de la miniatura con Content-Type: image/jpeg; 404 si no está disponible
GET /health	200 con el identificador de la instancia
8. Evidencias E1 a E7

Organizadas por etapa en evidencias/E1 … evidencias/E7.

Etapa	Qué demuestra	Archivos principales
E1	Explicación con el diagrama y contraste con recursos desplegados	[COMPLETAR] (diagrama, salida de docker ps y kubectl get all -n lomax)
E2	Restricciones en RDS, atributos variables en DynamoDB, persistencia tras reinicio	E2_restricciones.txt, E2_rds_antes.txt, E2_rds_despues.txt, E2_dynamo_antes.txt, E2_dynamo_despues.txt
E3	Lambda: éxito de transporte y funcional, dimensiones 1200×800 → 300×200, idempotencia, caso inválido, PNG	E3_invoke_1_transporte.txt, E3_invoke_1_respuesta.json, E3_dimensiones.txt, mini_1.jpg, E3_dynamo_1.txt, E3_invoke_1b_respuesta.json, E3_invoke_2_respuesta.json, E3_dynamo_2_error.txt, E3_invoke_2_reintento.json, E3_invoke_5_png.json, E3_ls_originales.txt, E3_ls_miniaturas.txt
E4	Todos los endpoints con datos válidos e inválidos, verificación directa en RDS, DynamoDB y S3, error 503 con RDS caído	E4_reporte.txt, E4_api_mini.jpg, E4_s3_mini.jpg, E4_503.txt
E5	Catálogo de 20 productos coherente en RDS, DynamoDB y S3; flujos desde la interfaz	E5_seed.txt, E5_verificacion_rds.txt, capturas del navegador [PENDIENTE: COMPLETAR]
E6	Push, digest remoto, pull y ejecución de las imágenes desde ECR	E6_push_backend.txt, E6_push_frontend.txt, E6_pull_backend.txt, E6_pull_frontend.txt
E7	Pods con imágenes de ECR, escalado a 3, reemplazo de Pod con UID distinto, persistencia tras recrear Pods	E7_imagenes_pods.txt, E7_escalado.txt, E7_escalado_reparto.txt, E7_uid.txt, E7_nuevo_rds.txt, E7_nuevo_dynamo.txt, E7_mini_nuevo.jpg, E7_mini_endpoint.jpg, E7_nuevo_tras_recreacion.txt, E7_pods_recreados.txt, E7_pull_test.txt

Resultados clave observados:

E2: los rechazos de código duplicado, precio negativo y categoría inexistente no dejan registros parciales. Los datos de RDS y DynamoDB son idénticos antes y después de reiniciar.
E3: el original de 1200 × 800 produce una miniatura de 300 × 200. Repetir la invocación no crea objetos adicionales (clave determinista). Un archivo inválido deja el estado ERROR y no genera miniatura.
E4: con RDS apagado la API responde 503 con paso_fallido: rds y se recupera al volver a encenderlo, sin reiniciar el proceso.
E5: al completar los 20 publicados había 20 productos PUBLICADO en RDS, 20 items LISTA en DynamoDB y 20 miniaturas en S3, más 2 productos PENDIENTE de casos de prueba que no aparecen en el catálogo. Después se registraron más productos en las pruebas de E7 y E5, por lo que el catálogo actual tiene más de 20.
E6: el digest reportado por docker push coincide con el de ecr describe-images.
E7: backend y frontend corren con los digests publicados en ECR (sha256:19ade50a… y sha256:86885d5b…). El reparto con 3 réplicas fue de 22, 19 y 19 peticiones sobre 60. Tras recrear todos los Pods, un producto registrado en EKS siguió disponible (catálogo con 21 productos).
9. Guía para la defensa
Reto	Cómo demostrarlo
Explicar el diagrama	Ver sección 2 y el diagrama de la Etapa 1.
Recorrido de un producto y por qué uno incompleto queda PENDIENTE	Sección 2.2: solo pasa a PUBLICADO si confirma atributos, estado LISTA y miniatura en S3.
Rechazo de código duplicado, atributos variables, persistencia tras reinicio	scripts\demo_e2.ps1; docker restart floci y repetir las consultas.
Localizar y descargar la miniatura, comprobar dimensiones, repetir Lambda sin duplicados	aws s3 ls, aws s3api get-object, dimensiones con System.Drawing, segunda invocación y comparar el conteo de objetos (ver Etapa 3).
Endpoints válidos e inválidos y completar un registro pendiente	scripts\test_api.ps1; para reintentar: POST /productos/{id}/reprocesar o volver a subir la imagen.
Registrar y consultar desde el dashboard con datos de los servicios	http://localhost:8080 (o 8090 en EKS); el panel "Solicitudes HTTP" del formulario muestra las llamadas.
Push, digest remoto, pull y ejecución desde ECR	Sección Etapa 6 y evidencias/E6.
Imágenes de los Pods, escalado a 3, reemplazo sin pérdida	Sección Etapa 7.
10. Decisiones de diseño
Estado PENDIENTE/PUBLICADO: un producto solo es visible cuando todas sus partes existen (fila en RDS, atributos en DynamoDB, miniatura en S3). Un fallo intermedio deja el producto en PENDIENTE y reintentable, sin obligar a registrar de nuevo.
Clave de miniatura determinista (miniaturas/{producto_id}.jpg): repetir el procesamiento sobrescribe el mismo objeto y no acumula duplicados.
Dos niveles de éxito en Lambda: la función atrapa sus errores y responde ok:false; así queda el estado ERROR registrado en DynamoDB y la API decide el código HTTP. Por eso lambda invoke devuelve 200 aunque la imagen sea inválida.
Validación en capas: el navegador comprueba tipo (por extensión), tamaño y campos; la API valida la firma real del archivo (JPEG o PNG); Lambda decodifica la imagen. Ninguna capa sustituye a la siguiente.
Persistencia fuera de los Pods: RDS, DynamoDB y S3 guardan los datos; los Pods no guardan nada, por eso se pueden borrar y recrear.
Sin clave foránea entre servicios: la API es quien verifica que el producto_id de DynamoDB exista en RDS.
Huecos en los producto_id: los SERIAL de PostgreSQL consumen un valor aunque el INSERT falle o ON CONFLICT DO NOTHING no inserte. Es esperable y no indica pérdida de datos.
11. Limitaciones conocidas
Dependencia de la IP de Floci (172.19.0.2). El registries.yaml que Floci escribe en k3s y el hostAliases del backend apuntan a esa IP. Si se recrea el contenedor floci o la red y cambia la IP, ECR y los Pods dejan de funcionar hasta ajustar ambos. Por eso floci no se recrea durante la validación de EKS.
Los Pods no resuelven floci por el DNS del clúster. CoreDNS no conoce el DNS interno de Docker; se resuelve con hostAliases en el Deployment del backend. En AWS real los servicios tienen DNS público y esto no haría falta.
kubectl port-forward se cae en silencio (por ejemplo, al reemplazar el Pod del proxy). Síntoma: curl a localhost:8090 falla. Solución: volver a lanzar el comando.
Autenticación de kubectl: el clúster es un k3s con certificado de cliente; el kubeconfig de aws eks update-kubeconfig (token IAM) no autentica, por eso se extrae el k3s.yaml del contenedor.
Registro incompleto sin endpoint para completar atributos: si RDS acepta el producto pero falla DynamoDB, el producto queda PENDIENTE sin atributos y repetir el POST devuelve 409 (código duplicado). El enunciado solo exige reintento de la imagen.
Prueba de error 502 no ejecutada: el fallo de un servicio dependiente se demostró con RDS caído (503). La rama de Lambda (502) está implementada pero no probada.
Reconstrucción desde cero no validada: las etapas se ejecutaron en orden sobre el entorno de desarrollo; no se probó reconstruir todo en una máquina limpia.
Reparto del escalado: la primera medición (E7_escalado.txt), tomada unos segundos después de escalar, dejó un Pod sin tráfico. La medición posterior con las tres réplicas estables (E7_escalado_reparto.txt) muestra reparto equilibrado. No se investigó la causa de la primera.
Atributos numéricos: el formulario convierte a número los valores que lo parecen (por ejemplo pulgadas: 27), y guarda como texto el resto.
Credenciales de desarrollo en el repositorio (ver sección 5).
Los productos 1, 2 y 5 se procesaron primero con la CLI (Etapa 3) y se publicaron después con POST /productos/{id}/reprocesar.
