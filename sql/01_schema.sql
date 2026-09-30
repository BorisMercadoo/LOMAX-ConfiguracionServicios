CREATE TABLE IF NOT EXISTS categorias (
  categoria_id SERIAL PRIMARY KEY,
  nombre VARCHAR(80) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS productos (
  producto_id  SERIAL PRIMARY KEY,
  codigo       VARCHAR(40) NOT NULL UNIQUE,
  nombre       VARCHAR(120) NOT NULL,
  descripcion  TEXT NOT NULL,
  precio       NUMERIC(12,2) NOT NULL CHECK (precio >= 0),
  categoria_id INT NOT NULL REFERENCES categorias(categoria_id),
  fecha        TIMESTAMPTZ NOT NULL DEFAULT now(),
  estado       VARCHAR(10) NOT NULL DEFAULT 'PENDIENTE'
               CHECK (estado IN ('PENDIENTE','PUBLICADO'))
);