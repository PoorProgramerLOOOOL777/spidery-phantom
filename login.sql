-- ============================================================
--  Garabateadero · Base de datos del login
--  Motor: SQLite 3 (un solo archivo; no hace falta instalar un servidor de BD)
--
--  Cómo ejecutarlo:
--    sqlite3 garabateadero.db < login.sql
--  o desde Node con better-sqlite3:
--    db.exec(fs.readFileSync('login.sql', 'utf8'))
--
--  Lo que se escribe en loggin.html se guarda así:
--    campo "usuario"    ->  usuarios.usuario
--    campo "contrasena" ->  usuarios.contrasena_hash (como hash, nunca en claro)
--
--  Las fechas se guardan en hora UTC (AAAA-MM-DD HH:MM:SS).
-- ============================================================

-- SQLite exige activar las llaves foráneas en cada conexión
-- (hay que repetirlo en server.js al abrir la base).
PRAGMA foreign_keys = ON;


-- ------------------------------------------------------------
--  Usuarios
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS usuarios (
  id                INTEGER PRIMARY KEY AUTOINCREMENT,
  usuario           TEXT    COLLATE NOCASE NOT NULL UNIQUE
                            CHECK (length(usuario) BETWEEN 3 AND 30),    -- "Ana" y "ana" son el mismo usuario
  contrasena_hash   TEXT    NOT NULL
                            CHECK (length(contrasena_hash) >= 50),       -- frena guardar una contraseña en texto plano por error
  activo            INTEGER NOT NULL DEFAULT 1 CHECK (activo IN (0, 1)),  -- 0 = cuenta desactivada
  intentos_fallidos INTEGER NOT NULL DEFAULT 0,
  bloqueado_hasta   TEXT,                                                  -- NULL = sin bloqueo
  creado_en         TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  ultimo_acceso     TEXT
);


-- ------------------------------------------------------------
--  Sesiones (quién tiene la sesión iniciada)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sesiones (
  token_hash  TEXT    PRIMARY KEY,                                         -- SHA-256 del token; el token real solo vive en la cookie
  usuario_id  INTEGER NOT NULL REFERENCES usuarios (id) ON DELETE CASCADE,
  creado_en   TEXT    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expira_en   TEXT    NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_sesiones_usuario ON sesiones (usuario_id);
CREATE INDEX IF NOT EXISTS idx_sesiones_expira  ON sesiones (expira_en);


-- ------------------------------------------------------------
--  Primer usuario
--  El hash no se escribe a mano: lo genera bcrypt desde Node.
--    npm i bcryptjs
--    node -e "require('bcryptjs').hash('tu-clave', 12).then(console.log)"
--  Copia el resultado (empieza con $2) y guárdalo con la consulta 1.
-- ------------------------------------------------------------


-- ============================================================
--  Consultas que usará server.js
--  Siempre con parámetros "?": lo que escribe la persona nunca
--  se pega dentro del SQL (así se evita la inyección SQL).
-- ============================================================

-- 1) Registrar un usuario (el hash lo genera server.js con bcrypt)
--    INSERT INTO usuarios (usuario, contrasena_hash) VALUES (?, ?);

-- 2) Iniciar sesión: buscar al usuario. La contraseña se compara en
-- server.js con bcrypt.compare(contrasena, contrasena_hash).
-- Sin filas = usuario inexistente o desactivado; bloqueado = 1 = rechazar.
--    SELECT id, usuario, contrasena_hash,
--           (bloqueado_hasta IS NOT NULL AND bloqueado_hasta > CURRENT_TIMESTAMP) AS bloqueado
--      FROM usuarios
--     WHERE usuario = ? AND activo = 1;

-- 3) Contraseña correcta: reiniciar el contador y crear la sesión
--    UPDATE usuarios
--       SET intentos_fallidos = 0, bloqueado_hasta = NULL, ultimo_acceso = CURRENT_TIMESTAMP
--     WHERE id = ?;
--    INSERT INTO sesiones (token_hash, usuario_id, expira_en)
--    VALUES (?, ?, datetime('now', '+7 days'));

-- 4) Contraseña incorrecta: a los 5 fallos se bloquea 15 minutos
-- y el contador vuelve a 0
--    UPDATE usuarios
--       SET bloqueado_hasta   = CASE WHEN intentos_fallidos + 1 >= 5
--                                    THEN datetime('now', '+15 minutes') ELSE bloqueado_hasta END,
--           intentos_fallidos = CASE WHEN intentos_fallidos + 1 >= 5
--                                    THEN 0 ELSE intentos_fallidos + 1 END
--     WHERE id = ?;

-- 5) En cada petición: ¿la cookie corresponde a una sesión válida?
--    SELECT u.id, u.usuario
--      FROM sesiones s
--      JOIN usuarios u ON u.id = s.usuario_id
--     WHERE s.token_hash = ? AND s.expira_en > CURRENT_TIMESTAMP AND u.activo = 1;

-- 6) Cerrar sesión y limpiar las sesiones vencidas
--    DELETE FROM sesiones WHERE token_hash = ?;
--    DELETE FROM sesiones WHERE expira_en <= CURRENT_TIMESTAMP;
