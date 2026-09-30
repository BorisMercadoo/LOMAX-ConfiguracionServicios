import io, os
import boto3
from PIL import Image

ENDPOINT = os.environ.get("FLOCI_ENDPOINT") or os.environ.get("AWS_ENDPOINT_URL")
KW = dict(endpoint_url=ENDPOINT, region_name="us-east-1",
          aws_access_key_id="test", aws_secret_access_key="test")
s3 = boto3.client("s3", **KW)
ddb = boto3.client("dynamodb", **KW)

BUCKET_MINI = os.environ.get("BUCKET_MINIATURAS", "lomax-miniaturas")
TABLA = os.environ.get("TABLA_ATRIBUTOS", "productos_atributos")
MAX_BYTES = 5 * 1024 * 1024
MAX_SIDE = 300


def guardar_estado(pid, estado, original_key, mini_key=None, error=None):
    if mini_key:
        ddb.update_item(
            TableName=TABLA, Key={"producto_id": {"S": pid}},
            UpdateExpression="SET estado_procesamiento=:e, imagen_original_key=:o, miniatura_key=:m REMOVE error_procesamiento",
            ExpressionAttributeValues={":e": {"S": estado}, ":o": {"S": original_key}, ":m": {"S": mini_key}})
    else:
        ddb.update_item(
            TableName=TABLA, Key={"producto_id": {"S": pid}},
            UpdateExpression="SET estado_procesamiento=:e, imagen_original_key=:o, error_procesamiento=:x REMOVE miniatura_key",
            ExpressionAttributeValues={":e": {"S": estado}, ":o": {"S": original_key}, ":x": {"S": error or ""}})


def handler(event, context):
    pid = str(event["producto_id"])
    bucket = event["bucket"]
    key = event["key"]
    try:
        head = s3.head_object(Bucket=bucket, Key=key)
        if head["ContentLength"] > MAX_BYTES:
            raise ValueError("Archivo mayor a 5 MB")
        data = s3.get_object(Bucket=bucket, Key=key)["Body"].read()

        try:
            Image.open(io.BytesIO(data)).verify()
            img = Image.open(io.BytesIO(data))
        except Exception:
            raise ValueError("El archivo no es una imagen valida")
        if img.format not in ("JPEG", "PNG"):
            raise ValueError("Formato no permitido: " + str(img.format))

        orig = img.size
        if img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info):
            img = img.convert("RGBA")
            fondo = Image.new("RGB", img.size, (255, 255, 255))
            fondo.paste(img, mask=img.split()[3])
            img = fondo
        else:
            img = img.convert("RGB")

        img.thumbnail((MAX_SIDE, MAX_SIDE))
        buf = io.BytesIO()
        img.save(buf, "JPEG", quality=85)

        mini_key = "miniaturas/" + pid + ".jpg"
        s3.put_object(Bucket=BUCKET_MINI, Key=mini_key, Body=buf.getvalue(), ContentType="image/jpeg")
        guardar_estado(pid, "LISTA", key, mini_key)
        return {"ok": True, "producto_id": pid, "estado": "LISTA",
                "miniatura_key": mini_key, "original": list(orig), "miniatura": list(img.size)}
    except Exception as e:
        guardar_estado(pid, "ERROR", key, None, str(e)[:200])
        return {"ok": False, "producto_id": pid, "estado": "ERROR", "error": str(e)[:200]}