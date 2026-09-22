# Quincena · Nuestro hogar

Aplicación responsive HTML/CSS/JavaScript para GitHub Pages, Supabase Auth y Realtime. Interfaz clara en blanco, negro y gris, inspirada en la referencia proporcionada. Dos integrantes pueden registrar gastos, pagos, inventario y listas compartidas.

## Estado de entrega

Código y migración preparados. No asumir despliegue ni base de datos instalada hasta verificarlo en las cuentas destino. `public/config.js` ya apunta al proyecto proporcionado por el usuario con su clave publicable. Las tablas todavía deben instalarse.

## Puesta en marcha

1. Elige o crea un proyecto Supabase. Ejecuta completo `sql/001_schema.sql` en SQL Editor.
2. En Authentication → Users, crea dos cuentas con correo y contraseña, confirmadas. No publiques contraseñas en el código. Esta primera versión inicia sesión con contraseña; no ofrece registro abierto ni recuperación de contraseña dentro de la interfaz.
3. Copia la URL del proyecto y su clave **publishable** (o anon) a `public/config.js`. Nunca uses `service_role`, una clave secreta ni la contraseña de PostgreSQL.
4. El propietario inicia sesión y pulsa **Crear hogar**. En **Usuarios y ajustes**, habilita el correo exacto del segundo integrante. Esto no envía correos.
5. El segundo integrante inicia sesión con su cuenta confirmada y se une al hogar automáticamente. Debe esperar la habilitación antes de crear un hogar propio. Máximo dos integrantes por hogar; cada cuenta pertenece a un solo hogar.
6. En **Usuarios y ajustes → Importar respaldo**, carga `private/datos-iniciales.json` una sola vez. El respaldo contiene la despensa Walmart, compras reportadas y configuración. También puedes exportar e importar el respaldo generado por el demo anterior. La importación reemplaza los datos actuales tras confirmación.
7. Publica SOLO el código, excluyendo `private/`. La carpeta está en `.gitignore`, pero si cargas archivos manualmente en GitHub también debes excluirla. Los gastos personales no forman parte de `public/`.
8. En GitHub, crea el repositorio destino, sube el proyecto sin datos privados y selecciona **Settings → Pages → Source: GitHub Actions**. El workflow incluido publica únicamente `public/` al hacer push a `main`.
9. Abre la URL Pages en PC y en ambos celulares. Cada persona inicia sesión con su propia cuenta.

Para previsualizar: `python -m http.server 8765 --directory public` y abre `http://localhost:8765`. Sin configuración aparece **Explorar interfaz de prueba**. Esa vista es temporal, no utiliza la nube ni persiste cambios al recargar.

## Datos y permisos

- `households`: hogar y propietario.
- `household_members`: integrantes, roles y acceso (máximo 2 vía RPC).
- `household_invites`: correo autorizado para el segundo integrante, sin envío de mensajes.
- `household_state`: documento JSONB compartido con presupuesto, productos, movimientos, gastos, pagos, apartados y listas. Se usa un único agregado transaccional para conservar de manera atómica una compra, sus cantidades y el descuento del fondo.
- `household_audit`: autor, fecha y revisión de cada guardado; no es un historial de versiones recuperables.

Todas las tablas tienen RLS. Solo integrantes autenticados pueden leer su hogar. No hay escritura directa para anon/authenticated. Las RPC comprueban pertenencia, límite de usuarios y revisión antes de modificar datos. `save_household_state` bloquea la fila y exige `p_expected_revision`. Si dos usuarios guardan simultáneamente, el segundo recibe conflicto: se carga la revisión nueva y debe repetir su cambio, nunca se sobrescribe silenciosamente. La interfaz indica fallos de red y no promete guardado offline.

Realtime escucha `household_state`. Además, se consulta cada 30 segundos y al volver a la pestaña o recuperar conexión. Los datos financieros no se guardan automáticamente en localStorage. Supabase administra la persistencia de la sesión de acceso.

## Funciones

- Nómina y vales separados; tarjeta bancaria, efectivo, vales o mixto.
- Apartado manual por compromiso. Agua inicialmente con vales; Rufi en efectivo de nómina; leche configurable.
- Preparar el efectivo no genera un segundo gasto. La aplicación no lleva subcuentas bancarias ni retiros reales: muestra origen de fondos y forma de pago.
- Pago de Rufi: viernes $1,400. Agua: miércoles $105. Leche: $219 cada 14 días desde 23/09/2026. Los importes recurrentes están centralizados en `events()` y pueden editarse al pagar; un editor de recurrencias será una ampliación posterior.
- Carne y pollo: referencia $550 semanales; compras reales variables, sin doble reserva.
- Inventario con cantidades decimales, consumo y ajuste. Los importes de envío no generan existencias. Carne molida pendiente de peso.
- Nueva lista, guardar lista anterior, reutilizar productos y marcar selección para una compra parcial. Registrar la compra actualiza inventario, gasto, fondo e historial de listas en una sola escritura.
- Historial de Walmart dentro de Movimientos cuando se importa el respaldo privado; importe conciliado con el ticket y disposición de efectivo excluida.
- Conteo de días al depósito según America/Monterrey.

## Límites de esta primera versión

No hay OCR, carga de tickets, conexión bancaria, notificaciones push ni modo offline. Las fechas y saldos de apertura se configuran manualmente al cambiar de periodo; no hay cierre y traspaso automático. El JSONB se conserva como un agregado con control de versión; una futura versión puede normalizar tablas de productos y transacciones para reportes extensos. No se instala una clave de servicio en el navegador. El HTML público no implica que los datos privados sean públicos: el acceso lo controla Supabase.

## Verificación de aceptación con el proyecto real

- Usuario A crea hogar y habilita B; un usuario C no puede leer ni modificar filas del hogar.
- A y B ven los mismos registros; A captura un gasto y B lo ve sin recargar.
- Guarda cambios simultáneos: uno recibe conflicto, sin pérdida silenciosa.
- Rufi exige efectivo; agua permite vales; las reservas disminuyen el disponible del fondo elegido.
- Compra parcial con vales: saldo e inventario cambian una vez; el producto desaparece de la lista activa.
- Desconecta internet e intenta guardar: debe verse el error y recuperarse la última versión confirmada.
- Verifica Pages en 390 px y escritorio; nunca subas private/ al repositorio.

## Referencias oficiales

- https://supabase.com/docs/guides/database/postgres/row-level-security
- https://supabase.com/docs/guides/realtime/postgres-changes
- https://supabase.com/docs/reference/javascript/auth-signinwithpassword
- https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages

## Pruebas reproducibles

`npm install` y `npm test`. Las pruebas usan datos ficticios, DOM simulado (JSDOM) y PostgreSQL embebido (PGlite). Verifican formularios, compra parcial, fondos, RLS, máximo de dos integrantes y conflictos. No sustituyen una prueba en el Supabase de destino ni una inspección visual del sitio publicado.
