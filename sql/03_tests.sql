\echo == 1. valida
INSERT INTO productos (codigo,nombre,descripcion,precio,categoria_id) VALUES ('TEC-002','Teclado 2','desc',40,1);
\echo == 2. codigo duplicado (debe fallar)
INSERT INTO productos (codigo,nombre,descripcion,precio,categoria_id) VALUES ('TEC-001','Otro','desc',40,1);
\echo == 3. precio negativo (debe fallar)
INSERT INTO productos (codigo,nombre,descripcion,precio,categoria_id) VALUES ('TEC-003','Neg','desc',-5,1);
\echo == 4. categoria inexistente (debe fallar)
INSERT INTO productos (codigo,nombre,descripcion,precio,categoria_id) VALUES ('TEC-004','Sin cat','desc',10,999);
\echo == 5. sin registros parciales
SELECT producto_id, codigo, precio FROM productos ORDER BY producto_id;