INSERT INTO categorias (nombre) VALUES ('Teclados'), ('Pantallas')
ON CONFLICT (nombre) DO NOTHING;

INSERT INTO productos (codigo, nombre, descripcion, precio, categoria_id)
SELECT 'TEC-001','Teclado mecanico K1','Teclado gamer',59.90,
       (SELECT categoria_id FROM categorias WHERE nombre='Teclados')
ON CONFLICT (codigo) DO NOTHING;

INSERT INTO productos (codigo, nombre, descripcion, precio, categoria_id)
SELECT 'PAN-001','Monitor 27 pulgadas','Monitor IPS',289.00,
       (SELECT categoria_id FROM categorias WHERE nombre='Pantallas')
ON CONFLICT (codigo) DO NOTHING;