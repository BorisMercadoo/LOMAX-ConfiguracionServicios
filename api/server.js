const express = require('express');
const multer = require('multer');
const os = require('os');
const { Pool } = require('pg');
const { S3Client, PutObjectCommand, GetObjectCommand, HeadObjectCommand, DeleteObjectCommand } = require('@aws-sdk/client-s3');
const { DynamoDBClient, PutItemCommand, GetItemCommand, UpdateItemCommand, BatchGetItemCommand } = require('@aws-sdk/client-dynamodb');
const { LambdaClient, InvokeCommand } = require('@aws-sdk/client-lambda');
const { marshall, unmarshall } = require('@aws-sdk/util-dynamodb');

const B_ORIG = process.env.BUCKET_ORIGINALES || 'lomax-originales';
const B_MINI = process.env.BUCKET_MINIATURAS || 'lomax-miniaturas';
const TABLA = process.env.TABLA_ATRIBUTOS || 'productos_atributos';
const LAMBDA = process.env.LAMBDA_NAME || 'lomax-miniatura';
const MAX_BYTES = 5 * 1024 * 1024;

const cfg = {
  endpoint: process.env.AWS_ENDPOINT_URL || 'http://floci:4566',
  region: 'us-east-1',
  credentials: { accessKeyId: 'test', secretAccessKey: 'test' },
};
const s3 = new S3Client({ ...cfg, forcePathStyle: true });
const ddb = new DynamoDBClient(cfg);
const lambda = new LambdaClient(cfg);
const pool = new Pool({
  host: process.env.DB_HOST || 'floci',
  port: Number(process.env.DB_PORT || 7001),
  user: process.env.DB_USER || 'admin',
  password: process.env.DB_PASSWORD || 'admin12345',
  database: process.env.DB_NAME || 'lomax',
});

class ApiError extends Error {
  constructor(status, msg, extra = {}) { super(msg); this.status = status; this.extra = extra; }
}

// Ejecuta un paso contra un servicio y lo etiqueta si falla
async function paso(nombre, fn, status = 503) {
  try { return await fn(); }
  catch (e) {
    if (e instanceof ApiError) throw e;
    throw new ApiError(status, 'Fallo en el servicio ' + nombre,
      { paso_fallido: nombre, detalle: String(e.message).slice(0, 200) });
  }
}

const app = express();
app.use(express.json());
app.use((req, res, next) => {
  res.set('X-Instance', os.hostname());
  console.log(os.hostname() + ' ' + req.method + ' ' + req.url);
  next();
});

const idValido = (req, res, next) =>
  /^\d+$/.test(req.params.id) ? next() : next(new ApiError(400, 'producto_id invalido'));

const getRds = async (id) => (await paso('rds', () => pool.query(
  'SELECT p.producto_id, p.codigo, p.nombre, p.descripcion, p.precio::float8 AS precio, ' +
  'p.categoria_id, c.nombre AS categoria, p.fecha, p.estado ' +
  'FROM productos p JOIN categorias c ON c.categoria_id = p.categoria_id WHERE p.producto_id = $1', [id]))).rows[0];

const getItem = async (id) => {
  const r = await paso('dynamodb', () => ddb.send(new GetItemCommand(
    { TableName: TABLA, Key: { producto_id: { S: String(id) } } })));
  return r.Item ? unmarshall(r.Item) : null;
};

function detectar(buf) {
  if (buf.length > 3 && buf[0] === 0xFF && buf[1] === 0xD8 && buf[2] === 0xFF) return { ext: 'jpg', mime: 'image/jpeg' };
  const png = Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  if (buf.length > 8 && buf.subarray(0, 8).equals(png)) return { ext: 'png', mime: 'image/png' };
  return null;
}

// Invoca Lambda de forma sincrona, verifica y publica
async function procesar(id, key) {
  const extraBase = { producto_id: Number(id), estado: 'PENDIENTE' };
  let r;
  try {
    r = await lambda.send(new InvokeCommand({
      FunctionName: LAMBDA, InvocationType: 'RequestResponse',
      Payload: Buffer.from(JSON.stringify({ producto_id: String(id), bucket: B_ORIG, key })),
    }));
  } catch (e) {
    throw new ApiError(502, 'Fallo en el servicio lambda',
      { ...extraBase, paso_fallido: 'lambda', detalle: String(e.message).slice(0, 200) });
  }
  const texto = Buffer.from(r.Payload || []).toString('utf8');
  if (r.FunctionError) throw new ApiError(502, 'La funcion Lambda fallo',
    { ...extraBase, paso_fallido: 'lambda', detalle: texto.slice(0, 200) });
  let out;
  try { out = JSON.parse(texto); }
  catch { throw new ApiError(502, 'Respuesta de Lambda ilegible', { ...extraBase, paso_fallido: 'lambda' }); }
  if (!out.ok) throw new ApiError(415, 'La imagen no es valida o no se pudo procesar',
    { ...extraBase, paso_fallido: 'lambda', detalle: out.error });

  // Solo se publica si atributos y miniatura estan confirmados
  const item = await getItem(id);
  if (!item || !item.atributos || Object.keys(item.atributos).length === 0 ||
      item.estado_procesamiento !== 'LISTA' || !item.miniatura_key)
    throw new ApiError(409, 'Registro incompleto: faltan atributos o miniatura',
      { ...extraBase, paso_fallido: 'dynamodb' });
  await paso('s3', () => s3.send(new HeadObjectCommand({ Bucket: B_MINI, Key: item.miniatura_key })));
  await paso('rds', () => pool.query("UPDATE productos SET estado='PUBLICADO' WHERE producto_id=$1", [id]));
  return { producto_id: Number(id), estado: 'PUBLICADO', miniatura_key: item.miniatura_key };
}

app.get('/health', (req, res) => res.json({ ok: true, instancia: os.hostname() }));

app.get('/categorias', async (req, res, next) => {
  try {
    const r = await paso('rds', () => pool.query('SELECT categoria_id, nombre FROM categorias ORDER BY categoria_id'));
    res.json(r.rows);
  } catch (e) { next(e); }
});

app.post('/productos', async (req, res, next) => {
  try {
    const b = req.body || {};
    const precio = (typeof b.precio === 'string' && b.precio.trim() !== '') ? Number(b.precio) : b.precio;
    const catId = (b.categoria_id === null || b.categoria_id === '' || b.categoria_id === undefined) ? NaN : Number(b.categoria_id);
    const campos = [];
    if (typeof b.codigo !== 'string' || !b.codigo.trim() || b.codigo.length > 40) campos.push('codigo');
    if (typeof b.nombre !== 'string' || !b.nombre.trim() || b.nombre.length > 120) campos.push('nombre');
    if (typeof b.descripcion !== 'string' || !b.descripcion.trim()) campos.push('descripcion');
    if (typeof precio !== 'number' || !isFinite(precio) || precio < 0) campos.push('precio');
    if (!Number.isInteger(catId)) campos.push('categoria_id');
    if (!b.atributos || typeof b.atributos !== 'object' || Array.isArray(b.atributos) ||
        Object.keys(b.atributos).length === 0) campos.push('atributos');
    if (campos.length) throw new ApiError(400, 'Datos invalidos', { campos });

    let id;
    try {
      const r = await pool.query(
        "INSERT INTO productos (codigo, nombre, descripcion, precio, categoria_id) VALUES ($1,$2,$3,$4,$5) RETURNING producto_id",
        [b.codigo.trim(), b.nombre.trim(), b.descripcion.trim(), precio, catId]);
      id = r.rows[0].producto_id;
    } catch (e) {
      if (e.code === '23505') throw new ApiError(409, 'Codigo de producto duplicado', { paso_fallido: 'rds' });
      if (e.code === '23503') throw new ApiError(400, 'La categoria no existe', { paso_fallido: 'rds', campos: ['categoria_id'] });
      if (e.code === '23514') throw new ApiError(400, 'Precio invalido', { paso_fallido: 'rds', campos: ['precio'] });
      throw new ApiError(503, 'Fallo en el servicio rds', { paso_fallido: 'rds', detalle: String(e.message).slice(0, 200) });
    }
    try {
      await paso('dynamodb', () => ddb.send(new PutItemCommand({
        TableName: TABLA,
        Item: marshall({ producto_id: String(id), atributos: b.atributos, estado_procesamiento: 'PENDIENTE' },
          { removeUndefinedValues: true }),
      })));
    } catch (e) {
      e.extra = { ...(e.extra || {}), producto_id: id, estado: 'PENDIENTE' };
      throw e;
    }
    res.status(201).json({ producto_id: id, estado: 'PENDIENTE' });
  } catch (e) { next(e); }
});

const upload = multer({ storage: multer.memoryStorage(), limits: { fileSize: MAX_BYTES } }).single('imagen');
const subir = (req, res, next) => upload(req, res, (err) => {
  if (!err) return next();
  if (err.code === 'LIMIT_FILE_SIZE') return next(new ApiError(413, 'Archivo mayor a 5 MB'));
  next(new ApiError(400, 'Solicitud de archivo invalida'));
});

app.post('/productos/:id/imagen', idValido, subir, async (req, res, next) => {
  try {
    const id = req.params.id;
    const p = await getRds(id);
    if (!p) throw new ApiError(404, 'Producto no existe');
    if (!req.file) throw new ApiError(400, 'Falta el campo imagen', { campos: ['imagen'] });
    const tipo = detectar(req.file.buffer);
    if (!tipo) throw new ApiError(415, 'Solo se permite JPEG o PNG valido');
    const item = await getItem(id);
    if (!item) throw new ApiError(409, 'El producto no tiene atributos registrados', { paso_fallido: 'dynamodb' });

    const key = 'originales/' + id + '.' + tipo.ext;
    await paso('s3', () => s3.send(new PutObjectCommand(
      { Bucket: B_ORIG, Key: key, Body: req.file.buffer, ContentType: tipo.mime })));
    if (item.imagen_original_key && item.imagen_original_key !== key) {
      await s3.send(new DeleteObjectCommand({ Bucket: B_ORIG, Key: item.imagen_original_key })).catch(() => {});
    }
    await paso('dynamodb', () => ddb.send(new UpdateItemCommand({
      TableName: TABLA, Key: { producto_id: { S: String(id) } },
      UpdateExpression: 'SET imagen_original_key=:o, estado_procesamiento=:e',
      ExpressionAttributeValues: { ':o': { S: key }, ':e': { S: 'PENDIENTE' } },
    })));
    res.status(200).json(await procesar(id, key));
  } catch (e) { next(e); }
});

app.post('/productos/:id/reprocesar', idValido, async (req, res, next) => {
  try {
    const id = req.params.id;
    const p = await getRds(id);
    if (!p) throw new ApiError(404, 'Producto no existe');
    const item = await getItem(id);
    if (!item || !item.imagen_original_key)
      throw new ApiError(409, 'No existe imagen original para reprocesar', { paso_fallido: 's3' });
    try {
      await s3.send(new HeadObjectCommand({ Bucket: B_ORIG, Key: item.imagen_original_key }));
    } catch (e) {
      if (e.name === 'NotFound' || (e.$metadata && e.$metadata.httpStatusCode === 404))
        throw new ApiError(409, 'No existe imagen original para reprocesar', { paso_fallido: 's3' });
      throw new ApiError(503, 'Fallo en el servicio s3', { paso_fallido: 's3', detalle: String(e.message).slice(0, 200) });
    }
    res.status(200).json(await procesar(id, item.imagen_original_key));
  } catch (e) { next(e); }
});

app.get('/productos', async (req, res, next) => {
  try {
    const r = await paso('rds', () => pool.query(
      "SELECT p.producto_id, p.codigo, p.nombre, p.descripcion, p.precio::float8 AS precio, " +
      "p.categoria_id, c.nombre AS categoria, p.fecha, p.estado " +
      "FROM productos p JOIN categorias c ON c.categoria_id = p.categoria_id " +
      "WHERE p.estado = 'PUBLICADO' ORDER BY p.producto_id"));
    const mapa = {};
    const ids = r.rows.map((x) => String(x.producto_id));
    for (let i = 0; i < ids.length; i += 100) {
      const lote = ids.slice(i, i + 100);
      const d = await paso('dynamodb', () => ddb.send(new BatchGetItemCommand({
        RequestItems: { [TABLA]: { Keys: lote.map((x) => ({ producto_id: { S: x } })) } },
      })));
      (d.Responses[TABLA] || []).forEach((it) => { const u = unmarshall(it); mapa[u.producto_id] = u; });
    }
    res.json(r.rows.map((x) => {
      const it = mapa[String(x.producto_id)] || {};
      return { ...x, atributos: it.atributos || {}, miniatura_key: it.miniatura_key || null,
               imagen_url: '/productos/' + x.producto_id + '/imagen' };
    }));
  } catch (e) { next(e); }
});

app.get('/productos/:id', idValido, async (req, res, next) => {
  try {
    const p = await getRds(req.params.id);
    if (!p) throw new ApiError(404, 'Producto no existe');
    const it = await getItem(req.params.id);
    res.json({ ...p, atributos: it ? it.atributos || {} : null,
      estado_procesamiento: it ? it.estado_procesamiento || null : null,
      miniatura_key: it ? it.miniatura_key || null : null,
      error_procesamiento: it ? it.error_procesamiento || null : null,
      imagen_url: '/productos/' + p.producto_id + '/imagen' });
  } catch (e) { next(e); }
});

app.get('/productos/:id/imagen', idValido, async (req, res, next) => {
  try {
    const it = await getItem(req.params.id);
    if (!it || it.estado_procesamiento !== 'LISTA' || !it.miniatura_key)
      throw new ApiError(404, 'Miniatura no disponible');
    let obj;
    try {
      obj = await s3.send(new GetObjectCommand({ Bucket: B_MINI, Key: it.miniatura_key }));
    } catch (e) {
      if (e.name === 'NoSuchKey') throw new ApiError(404, 'Miniatura no disponible');
      throw new ApiError(503, 'Fallo en el servicio s3', { paso_fallido: 's3', detalle: String(e.message).slice(0, 200) });
    }
    const bytes = Buffer.from(await obj.Body.transformToByteArray());
    res.set('Content-Type', obj.ContentType || 'image/jpeg');
    res.set('Content-Length', String(bytes.length));
    res.end(bytes);
  } catch (e) { next(e); }
});

app.use((err, req, res, next) => {
  if (err instanceof ApiError) return res.status(err.status).json({ error: err.message, ...err.extra });
  if (err.type === 'entity.parse.failed') return res.status(400).json({ error: 'JSON invalido' });
  console.error(err);
  res.status(500).json({ error: 'Error interno' });
});

app.listen(3000, '0.0.0.0', () => console.log('API lista en :3000'));