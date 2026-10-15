using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Authorization;
using Microsoft.Data.SqlClient;
using Microsoft.IdentityModel.Tokens;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Data;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using api_transporte_personal.Domain.Models;
using api_transporte_personal.Domain.UseCase;
using api_transporte_personal.Infraestructure.Services;

namespace api_transporte_personal.Controllers
{
    [ApiController]
    [Authorize]
    [Route("api/transporte")]
    public class TransporteController : ControllerBase
    {
        private readonly string _connectionString;
        private readonly ILogger<TransporteController> _logger;
        private readonly ITransporteUseCase _useCase;
        private readonly SymmetricSecurityKey _signingKey;
        private readonly LogisticaClient _logistica;

        public TransporteController(IConfiguration configuration, ILogger<TransporteController> logger, ITransporteUseCase useCase, SymmetricSecurityKey signingKey, LogisticaClient logistica)
        {
            _connectionString = configuration.GetConnectionString("DefaultConnection")!;
            _logger = logger;
            _useCase = useCase;
            _signingKey = signingKey;
            _logistica = logistica;
        }

        #region Auth

        [AllowAnonymous]
        [HttpPost("auth/login")]
        public async Task<IActionResult> Login([FromBody] List<LoginRequest> request)
        {
            try
            {
                if (request == null || request.Count == 0)
                    return BadRequest(new { mensaje = "Request inválido" });

                var login = request[0];

                var resultado = new List<object>();

                using var conn = new SqlConnection(_connectionString);
                await conn.OpenAsync();

                using var cmd = new SqlCommand("TRANSPORTE_login", conn);
                cmd.CommandType = CommandType.StoredProcedure;
                cmd.Parameters.AddWithValue("@usuario", login.Usuario);
                cmd.Parameters.AddWithValue("@claveHash", string.Empty);

                using var reader = await cmd.ExecuteReaderAsync();
                while (await reader.ReadAsync())
                {
                    if (!VerifyPassword(login.Clave, reader.GetString(7))) continue;
                    resultado.Add(new
                    {
                        idUsuario = reader.GetInt32(0),
                        usuario = reader.GetString(1),
                        nombre = reader.GetString(2),
                        idrol = reader.GetString(3),
                        rol = reader.GetString(4),
                        placa = reader.IsDBNull(5) ? null : reader.GetString(5),
                        area = reader.IsDBNull(6) ? null : reader.GetString(6),
                        idArea = reader.FieldCount > 8 && !reader.IsDBNull(8) ? reader.GetInt32(8) : (int?)null,
                        token = GenerateToken(reader.GetInt32(0), reader.GetString(1), reader.GetString(3))
                    });
                }
                await reader.CloseAsync();
                if (resultado.Count > 0)
                {
                    using var audit = new SqlCommand("INSERT INTO TP_AUDITORIA(entidad,accion,usuario,detalle) VALUES('SESION','LOGIN',@usuario,NULL)", conn);
                    audit.Parameters.AddWithValue("@usuario", login.Usuario);
                    await audit.ExecuteNonQueryAsync();
                }

                return Ok(resultado);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error en login transporte");
                return StatusCode(500, new { mensaje = "Error interno del servidor" });
            }
        }

        [HttpPost("auth/cambiar-clave")]
        public async Task<IActionResult> CambiarClave([FromBody] JsonElement body)
        {
            try
            {
                var usuario = body.TryGetProperty("usuario", out var u) ? u.GetString() : null;
                var claveActual = body.TryGetProperty("claveActual", out var ca) ? ca.GetString() ?? "" : "";
                var claveNueva = body.TryGetProperty("claveNueva", out var cn) ? cn.GetString() ?? "" : "";

                if (string.IsNullOrWhiteSpace(usuario) || claveNueva.Length < 6)
                    return BadRequest(new { mensaje = "La nueva clave debe tener al menos 6 caracteres" });

                var usuarioToken = User.Identity?.Name;
                var rolToken = User.FindFirst(ClaimTypes.Role)?.Value;
                if (usuario != usuarioToken && rolToken != "ADTRANS")
                    return StatusCode(403, new { mensaje = "Solo puede cambiar su propia clave" });

                using var conn = new SqlConnection(_connectionString);
                await conn.OpenAsync();

                string? hashActual = null;
                using (var cmd = new SqlCommand("TRANSPORTE_login", conn))
                {
                    cmd.CommandType = CommandType.StoredProcedure;
                    cmd.Parameters.AddWithValue("@usuario", usuario);
                    cmd.Parameters.AddWithValue("@claveHash", string.Empty);
                    using var reader = await cmd.ExecuteReaderAsync();
                    if (await reader.ReadAsync()) hashActual = reader.GetString(7);
                }

                if (hashActual == null)
                    return BadRequest(new { mensaje = "Usuario no encontrado" });
                if (!VerifyPassword(claveActual, hashActual))
                    return BadRequest(new { mensaje = "La clave actual es incorrecta" });

                using (var upd = new SqlCommand("UPDATE TP_USUARIOS SET claveHash=@h WHERE usuario=@u", conn))
                {
                    upd.Parameters.AddWithValue("@h", HashPassword(claveNueva));
                    upd.Parameters.AddWithValue("@u", usuario);
                    await upd.ExecuteNonQueryAsync();
                }

                using (var audit = new SqlCommand("INSERT INTO TP_AUDITORIA(entidad,accion,usuario,detalle) VALUES('USUARIO','CAMBIAR_CLAVE',@u,NULL)", conn))
                {
                    audit.Parameters.AddWithValue("@u", usuario);
                    await audit.ExecuteNonQueryAsync();
                }

                return Ok(new[] { new { mensaje = "Clave actualizada correctamente" } });
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error cambiando clave");
                return StatusCode(500, new { mensaje = "Error interno del servidor" });
            }
        }

        #endregion

        #region Solicitudes

        [HttpPost("solicitudes/listar")]
        public async Task<IActionResult> ListarSolicitudes([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ListarSolicitudesAsync(body.GetRawText()));

        [Authorize(Roles = "SPTRANS,COTRANS,ADTRANS")]
        [HttpPost("solicitudes/guardar")]
        public async Task<IActionResult> GuardarSolicitud([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.GuardarSolicitudAsync(body.GetRawText()));

        [Authorize(Roles = "SPTRANS,COTRANS,ADTRANS")]
        [HttpPost("solicitudes/eliminar")]
        public async Task<IActionResult> EliminarSolicitud([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.EliminarSolicitudAsync(body.GetRawText()));

        [HttpPost("solicitudes/realizado")]
        public async Task<IActionResult> MarcarRealizado([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.MarcarRealizadoAsync(body.GetRawText()));

        [Authorize(Roles = "CHTRANS,COTRANS,ADTRANS")]
        [HttpPost("solicitudes/estado")]
        public async Task<IActionResult> CambiarEstado([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.CambiarEstadoAsync(body.GetRawText()));

        #endregion

        #region Traslados

        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("solicitudes/asignar")]
        public async Task<IActionResult> AsignarUnidad([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.AsignarUnidadAsync(body.GetRawText()));

        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("solicitudes/desasignar")]
        public async Task<IActionResult> DesasignarUnidad([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.DesasignarUnidadAsync(body.GetRawText()));

        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("traslados/unir")]
        public async Task<IActionResult> UnirSolicitudes([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.UnirSolicitudesAsync(body.GetRawText()));

        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("traslados/separar")]
        public async Task<IActionResult> SepararSolicitud([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.SepararSolicitudAsync(body.GetRawText()));

        [HttpPost("traslados/listar")]
        public async Task<IActionResult> ListarTraslados([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ListarTrasladosAsync(body.GetRawText()));

        [Authorize(Roles = "COTRANS,ADTRANS,SPTRANS")]
        [HttpPost("traslados/progreso")]
        public async Task<IActionResult> TrasladoProgreso([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.TrasladoProgresoAsync(body.GetRawText()));

        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("traslados/paradas")]
        public async Task<IActionResult> GuardarParadas([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.GuardarParadasAsync(body.GetRawText()));

        [Authorize(Roles = "SPTRANS,COTRANS,ADTRANS")]
        [HttpPost("traslados/acoplar")]
        public async Task<IActionResult> AcoplarSolicitud([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.AcoplarSolicitudAsync(body.GetRawText()));

        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("solicitudes/asignar-multiples")]
        public async Task<IActionResult> AsignarMultiplesUnidades([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.AsignarMultiplesUnidadesAsync(body.GetRawText()));

        #endregion

        #region Conductor

        [Authorize(Roles = "CHTRANS,COTRANS,ADTRANS,SPTRANS")]
        [HttpPost("conductor/servicios")]
        public async Task<IActionResult> ServiciosConductor([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ListarServiciosConductorAsync(body.GetRawText()));

        [Authorize(Roles = "CHTRANS,COTRANS,ADTRANS")]
        [HttpPost("conductor/agregar-pasajeros")]
        public async Task<IActionResult> AgregarPasajeros([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.AgregarPasajerosAsync(body.GetRawText()));

        #endregion

        #region Seguimiento de paradas

        [Authorize(Roles = "CHTRANS,COTRANS,ADTRANS")]
        [HttpPost("paradas/llegada")]
        public async Task<IActionResult> ParadaLlegada([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ParadaLlegadaAsync(body.GetRawText()));

        [Authorize(Roles = "CHTRANS,COTRANS,ADTRANS")]
        [HttpPost("paradas/registrar")]
        public async Task<IActionResult> ParadaRegistrar([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ParadaRegistrarAsync(body.GetRawText()));

        [Authorize(Roles = "CHTRANS,COTRANS,ADTRANS")]
        [HttpPost("paradas/omitir")]
        public async Task<IActionResult> ParadaOmitir([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ParadaOmitirAsync(body.GetRawText()));

        [Authorize(Roles = "CHTRANS,COTRANS,ADTRANS")]
        [HttpPost("paradas/imprevista")]
        public async Task<IActionResult> ParadaImprevista([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ParadaImprevistaAsync(body.GetRawText()));

        // Ping GPS del conductor: posición en vivo de la unidad en ruta
        [Authorize(Roles = "CHTRANS,COTRANS,ADTRANS")]
        [HttpPost("unidades/ubicacion")]
        public async Task<IActionResult> ReportarUbicacion([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ReportarUbicacionAsync(body.GetRawText()));

        #endregion

        #region Catálogos

        [HttpPost("catalogos/puntos")]
        public async Task<IActionResult> ListarPuntos([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ListarPuntosAsync(body.GetRawText()));

        [HttpPost("catalogos/unidades")]
        public async Task<IActionResult> ListarUnidades([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ListarUnidadesAsync(body.GetRawText()));

        [HttpPost("catalogos/motivos")]
        public async Task<IActionResult> ListarMotivos([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ListarMotivosAsync(body.GetRawText()));

        [Authorize(Roles = "ADTRANS,COTRANS")]
        [HttpPost("administracion/catalogo")]
        public async Task<IActionResult> AdministrarCatalogo([FromBody] JsonElement body)
        {
            var datos = JsonSerializer.Deserialize<Dictionary<string, object?>>(body.GetRawText()) ?? [];
            // La identidad del actor sale del JWT, nunca del JSON del cliente.
            var rol = User.FindFirst(ClaimTypes.Role)?.Value;
            var usuario = User.FindFirst(ClaimTypes.Name)?.Value;
            datos["rolSolicitante"] = rol;
            datos["actor"] = usuario;
            if (rol == "COTRANS")
            {
                // El coordinador gestiona usuarios (conductores y supervisores), áreas,
                // unidades (flota propia/tercero), tipos de vehículo, puntos de ruta
                // y los catálogos de las OS (transportistas y tarifas). Puede LISTAR
                // el resto (solo lectura para selects); GUARDAR/ELIMINAR restringido.
                var entidad = datos.TryGetValue("entidad", out var e) ? e?.ToString()?.ToUpperInvariant() : null;
                var accion = datos.TryGetValue("accion", out var a) ? a?.ToString() : null;
                var esLectura = string.Equals(accion, "LISTAR", StringComparison.OrdinalIgnoreCase);
                var entidadPermitida = entidad is "USUARIO" or "AREA" or "TRANSPORTISTA" or "TARIFA" or "CECO" or "UNIDAD" or "TIPO_VEHICULO" or "PUNTO";
                if (!esLectura && !entidadPermitida)
                    return StatusCode(403, new { mensaje = "El coordinador solo puede gestionar usuarios, áreas, unidades, tipos de vehículo, puntos, transportistas, tarifas y centros de costo" });
                if (!esLectura && datos.TryGetValue("idrol", out var r) && r?.ToString() is { } idrol
                    && idrol != "CHTRANS" && idrol != "SPTRANS")
                    return BadRequest(new { mensaje = "El coordinador solo puede crear conductores o supervisores" });
            }
            if (datos.TryGetValue("clave", out var clave) && clave is JsonElement elemento && elemento.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(elemento.GetString()))
                datos["claveHash"] = HashPassword(elemento.GetString()!);
            datos.Remove("clave");
            return await Ejecutar(() => _useCase.AdministrarCatalogoAsync(JsonSerializer.Serialize(datos)));
        }

        [HttpPost("notificaciones/listar")]
        public async Task<IActionResult> ListarNotificaciones([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ListarNotificacionesAsync(body.GetRawText()));

        [HttpPost("notificaciones/marcar-leida")]
        public async Task<IActionResult> MarcarNotificacion([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.MarcarNotificacionAsync(body.GetRawText()));

        #endregion

        #region Comunicados (horas sin servicio)
        // El coordinador publica rangos de horas sin servicio (unidades en
        // actividades programadas). Al guardar, el SP difunde una notificación
        // a supervisores/coordinadores/admin y TRANSPORTE_guardarSolicitud
        // rechaza crear solicitudes dentro del rango (emergencias sí pasan).

        // Lista completa de comunicados para el mantenedor
        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("comunicados/listar")]
        public async Task<IActionResult> ListarComunicados([FromBody] JsonElement body)
        {
            var datos = JsonSerializer.Deserialize<Dictionary<string, object?>>(body.GetRawText()) ?? [];
            datos["accion"] = "LISTAR";
            return await Ejecutar(() => _useCase.AdministrarComunicadoAsync(JsonSerializer.Serialize(datos)));
        }

        // Crea/edita un comunicado; actor = usuario del token
        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("comunicados/guardar")]
        public async Task<IActionResult> GuardarComunicado([FromBody] JsonElement body)
        {
            var datos = JsonSerializer.Deserialize<Dictionary<string, object?>>(body.GetRawText()) ?? [];
            datos["accion"] = "GUARDAR";
            datos["actor"] = User.FindFirst(ClaimTypes.Name)?.Value;
            return await Ejecutar(() => _useCase.AdministrarComunicadoAsync(JsonSerializer.Serialize(datos)));
        }

        // Desactiva (borrado lógico) un comunicado
        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("comunicados/eliminar")]
        public async Task<IActionResult> EliminarComunicado([FromBody] JsonElement body)
        {
            var datos = JsonSerializer.Deserialize<Dictionary<string, object?>>(body.GetRawText()) ?? [];
            datos["accion"] = "ELIMINAR";
            datos["actor"] = User.FindFirst(ClaimTypes.Name)?.Value;
            return await Ejecutar(() => _useCase.AdministrarComunicadoAsync(JsonSerializer.Serialize(datos)));
        }

        // Comunicados vigentes/próximos — cualquier usuario autenticado lo usa
        // para mostrar el banner y bloquear el formulario de solicitudes
        [HttpPost("comunicados/activos")]
        public async Task<IActionResult> ComunicadosActivos([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ComunicadosActivosAsync(body.GetRawText()));

        #endregion

        #region Reportes

        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("reportes/solicitudes")]
        public async Task<IActionResult> ReporteSolicitudes([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ReporteSolicitudesAsync(body.GetRawText()));

        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("reportes/indicadores")]
        public async Task<IActionResult> ReporteIndicadores([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ReporteIndicadoresAsync(body.GetRawText()));

        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("reportes/auditoria")]
        public async Task<IActionResult> ListarAuditoria([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ListarAuditoriaAsync(body.GetRawText()));

        #endregion

        #region Órdenes de servicio
        // Flujo OS: generar (previa o real) → migrar a logística → estado-spring.
        // La OS la firma ante logística el supervisor que hizo la solicitud (su DNI
        // va en payload.usuario); el coordinador solo opera la pantalla de generación.

        // Genera las OS del período agrupadas por transportista a partir de los
        // traslados REALIZADO no facturados. Con previa:true solo calcula.
        // Se inyecta el usuario del token para auditoría (quién genera).
        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("os/generar")]
        public async Task<IActionResult> GenerarOS([FromBody] JsonElement body)
        {
            var datos = JsonSerializer.Deserialize<Dictionary<string, object?>>(body.GetRawText()) ?? [];
            datos["usuario"] = User.FindFirst(ClaimTypes.Name)?.Value;
            return await Ejecutar(() => _useCase.GenerarOSAsync(JsonSerializer.Serialize(datos)));
        }

        // Lista las OS con su detalle de distribución y los traslados incluidos
        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("os/listar")]
        public async Task<IActionResult> ListarOS([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ListarOSAsync(body.GetRawText()));

        // Migra las OS generadas (o una sola si llega idOS) al app de logística,
        // que a su vez las envía a SPRING con su flujo propio (aprobación +
        // orden-servicio/sincronizar). Aquí solo se marca MIGRADA/ERROR con el
        // numeroOS que devuelve logística — el número SPRING se consulta aparte.
        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("os/migrar")]
        public async Task<IActionResult> MigrarOS([FromBody] JsonElement body)
        {
            var datos = JsonSerializer.Deserialize<Dictionary<string, object?>>(body.GetRawText()) ?? [];
            var filtro = new Dictionary<string, object?> { ["estado"] = "GENERADA" };
            if (datos.TryGetValue("idOS", out var idOS) && idOS is not null)
            {
                filtro["idOS"] = idOS;
                filtro.Remove("estado"); // permite reintentar una OS en ERROR
            }
            var ordenes = await _useCase.ListarOSAsync(JsonSerializer.Serialize(filtro));
            // El repo devuelve cada fila como un elemento; el SP FOR JSON produce
            // una sola fila con el arreglo completo — hay que desenvolverlo.
            var filas = ordenes.SelectMany(o => o.ValueKind == JsonValueKind.Array ? o.EnumerateArray() : Enumerable.Repeat(o, 1));
            var pendientes = filas.Where(o =>
                o.ValueKind == JsonValueKind.Object && o.TryGetProperty("estado", out var e)
                && (e.GetString() == "GENERADA" || e.GetString() == "ERROR")).ToList();
            if (pendientes.Count == 0)
                return Ok(new { mensaje = "No hay órdenes de servicio pendientes de migrar", migradas = 0 });

            var resultados = new List<object>();
            foreach (var os in pendientes)
            {
                var id = os.GetProperty("idOS").GetInt32();
                if (!os.TryGetProperty("payloadEnvio", out var p) || p.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(p.GetString()))
                {
                    resultados.Add(new { idOS = id, ok = false, error = "La OS no tiene payload de envío" });
                    continue;
                }
                var payload = JsonSerializer.Deserialize<JsonElement>(p.GetString()!);
                var resultado = await _logistica.IngresarTransporteAsync(payload);
                var marca = new Dictionary<string, object?>
                {
                    ["idOS"] = id,
                    ["estado"] = resultado.Ok ? "MIGRADA" : "ERROR",
                    ["numeroOS"] = resultado.NumeroOS,
                    ["respuesta"] = resultado.Respuesta,
                    ["ultimoError"] = resultado.Error
                };
                await _useCase.MarcarOSAsync(JsonSerializer.Serialize(marca));
                resultados.Add(new { idOS = id, ok = resultado.Ok, numeroOS = resultado.NumeroOS, error = resultado.Error });
            }
            return Ok(new { migradas = resultados.Count(r => (bool)r.GetType().GetProperty("ok")!.GetValue(r)!), resultados });
        }

        // Consulta en logística (orden-servicio/obtener-por-id por numeroOSExterno)
        // el estado de las OS migradas y trae el numeroOrdenSpring cuando ya fue
        // sincronizada al ERP. Idempotente: se puede llamar repetidamente hasta
        // que logística complete su aprobación + sincronización.
        // (o solo la indicada si llega idOS)
        [Authorize(Roles = "COTRANS,ADTRANS")]
        [HttpPost("os/estado-spring")]
        public async Task<IActionResult> EstadoSpringOS([FromBody] JsonElement body)
        {
            var datos = JsonSerializer.Deserialize<Dictionary<string, object?>>(body.GetRawText()) ?? [];
            var filtro = new Dictionary<string, object?> { ["estado"] = "MIGRADA" };
            if (datos.TryGetValue("idOS", out var idOS) && idOS is not null)
                filtro["idOS"] = idOS;
            var ordenes = await _useCase.ListarOSAsync(JsonSerializer.Serialize(filtro));
            var filas = ordenes.SelectMany(o => o.ValueKind == JsonValueKind.Array ? o.EnumerateArray() : Enumerable.Repeat(o, 1));
            var migradas = filas.Where(o => o.ValueKind == JsonValueKind.Object
                && o.TryGetProperty("numeroOSExterno", out var n) && n.ValueKind == JsonValueKind.String
                && !string.IsNullOrWhiteSpace(n.GetString())).ToList();
            if (migradas.Count == 0)
                return Ok(new { mensaje = "No hay OS migradas para consultar", consultadas = 0 });

            var resultados = new List<object>();
            foreach (var os in migradas)
            {
                var id = os.GetProperty("idOS").GetInt32();
                var numero = os.GetProperty("numeroOSExterno").GetString()!;
                var est = await _logistica.ConsultarEstadoAsync(numero);
                if (est.Ok && (est.NumeroOSSpring is not null || est.EstadoLogistica is not null))
                {
                    await _useCase.MarcarOSAsync(JsonSerializer.Serialize(new Dictionary<string, object?>
                    {
                        ["idOS"] = id,
                        ["numeroOSSpring"] = est.NumeroOSSpring,
                        ["estadoLogistica"] = est.EstadoLogistica
                    }));
                }
                resultados.Add(new { idOS = id, numeroOS = numero, numeroOSSpring = est.NumeroOSSpring, estadoLogistica = est.EstadoLogistica, error = est.Error });
            }
            return Ok(new { consultadas = resultados.Count, resultados });
        }

        // Simula el endpoint de logística (api/logistica/orden-servicio/ingresar-transporte)
        // para pruebas locales sin el servidor real. Solo con Logistica:MockHabilitado=true.
        [AllowAnonymous]
        [HttpPost("mock-logistica/ingresar-transporte")]
        public IActionResult MockIngresarTransporte([FromBody] JsonElement body)
        {
            if (!_logistica.Options.MockHabilitado) return NotFound();
            if (!body.TryGetProperty("ruc_transportista", out var ruc) || string.IsNullOrWhiteSpace(ruc.GetString()))
                return BadRequest(new { success = false, mensaje = "ruc_transportista es obligatorio" });
            if (!body.TryGetProperty("total_tarifa", out var tarifa) || tarifa.ValueKind != JsonValueKind.Number || tarifa.GetDecimal() <= 0)
                return BadRequest(new { success = false, mensaje = "total_tarifa debe ser mayor a cero" });
            var numeroOS = $"OS-MOCK-{DateTime.Now:yyyyMMdd}-{Random.Shared.Next(1000, 9999)}";
            return Ok(new { success = true, numeroOS, mensaje = "OS registrada en logística (mock)" });
        }

        // Simula orden-servicio/obtener-por-id de logística: cualquier OS ingresada
        // al mock se considera ya sincronizada en SPRING con número derivado.
        [AllowAnonymous]
        [HttpPost("mock-logistica/obtener-por-id")]
        public IActionResult MockObtenerPorId([FromBody] JsonElement body)
        {
            if (!_logistica.Options.MockHabilitado) return NotFound();
            var numero = body.TryGetProperty("numeroOrden", out var n) ? n.GetString() : null;
            if (string.IsNullOrWhiteSpace(numero))
                return BadRequest(new { success = false, mensaje = "numeroOrden es obligatorio" });
            return Ok(new
            {
                success = true,
                numeroOrden = numero,
                estado = "SINCRONIZADA",
                numeroOrdenSpring = numero.Replace("OS-MOCK", "APSO-MOCK")
            });
        }

        #endregion

        private async Task<IActionResult> Ejecutar(Func<Task<List<JsonElement>>> accion)
        {
            try
            {
                var resultado = await accion();
                return Ok(resultado);
            }
            catch (SqlException sqlEx)
            {
                // RAISERROR de validación en los SPs: es un error del cliente,
                // no del servidor — se devuelve 400 con el mensaje real
                var mensaje = sqlEx.Errors.Count > 0 ? sqlEx.Errors[0].Message : sqlEx.Message;
                _logger.LogWarning(sqlEx, "Validación de negocio rechazada por SQL");
                return BadRequest(new { mensaje });
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Error ejecutando operación de transporte");
                return StatusCode(500, new { mensaje = "Error interno del servidor" });
            }
        }

        private static string HashPassword(string password)
        {
            const int iterations = 120000;
            var salt = RandomNumberGenerator.GetBytes(16);
            var hash = Rfc2898DeriveBytes.Pbkdf2(password, salt, iterations, HashAlgorithmName.SHA256, 32);
            return $"PBKDF2${iterations}${Convert.ToBase64String(salt)}${Convert.ToBase64String(hash)}";
        }

        private static bool VerifyPassword(string password, string storedHash)
        {
            if (storedHash.StartsWith("PBKDF2$", StringComparison.Ordinal))
            {
                var parts = storedHash.Split('$');
                if (parts.Length != 4 || !int.TryParse(parts[1], out var iterations)) return false;
                var salt = Convert.FromBase64String(parts[2]);
                var expected = Convert.FromBase64String(parts[3]);
                var actual = Rfc2898DeriveBytes.Pbkdf2(password, salt, iterations, HashAlgorithmName.SHA256, expected.Length);
                return CryptographicOperations.FixedTimeEquals(actual, expected);
            }
            using var sha = SHA256.Create();
            var legacy = Convert.ToHexString(sha.ComputeHash(Encoding.UTF8.GetBytes(password))).ToLowerInvariant();
            return CryptographicOperations.FixedTimeEquals(Encoding.UTF8.GetBytes(legacy), Encoding.UTF8.GetBytes(storedHash.ToLowerInvariant()));
        }

        private string GenerateToken(int idUsuario, string usuario, string rol)
        {
            var claims = new[]
            {
                new Claim(JwtRegisteredClaimNames.Sub, idUsuario.ToString()),
                new Claim(JwtRegisteredClaimNames.UniqueName, usuario),
                new Claim(ClaimTypes.NameIdentifier, idUsuario.ToString()),
                new Claim(ClaimTypes.Name, usuario),
                new Claim(ClaimTypes.Role, rol)
            };
            var credentials = new SigningCredentials(_signingKey, SecurityAlgorithms.HmacSha256);
            var token = new JwtSecurityToken(
                issuer: "api-transporte-personal",
                audience: "transporte-personal",
                claims: claims,
                expires: DateTime.UtcNow.AddHours(8),
                signingCredentials: credentials);
            return new JwtSecurityTokenHandler().WriteToken(token);
        }
    }
}
