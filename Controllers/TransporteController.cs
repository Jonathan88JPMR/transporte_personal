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

        public TransporteController(IConfiguration configuration, ILogger<TransporteController> logger, ITransporteUseCase useCase, SymmetricSecurityKey signingKey)
        {
            _connectionString = configuration.GetConnectionString("DefaultConnection")!;
            _logger = logger;
            _useCase = useCase;
            _signingKey = signingKey;
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

        [Authorize(Roles = "CHTRANS,COTRANS,ADTRANS")]
        [HttpPost("conductor/servicios")]
        public async Task<IActionResult> ServiciosConductor([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.ListarServiciosConductorAsync(body.GetRawText()));

        [Authorize(Roles = "CHTRANS,COTRANS,ADTRANS")]
        [HttpPost("conductor/agregar-pasajeros")]
        public async Task<IActionResult> AgregarPasajeros([FromBody] JsonElement body)
            => await Ejecutar(() => _useCase.AgregarPasajerosAsync(body.GetRawText()));

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

        [Authorize(Roles = "ADTRANS")]
        [HttpPost("administracion/catalogo")]
        public async Task<IActionResult> AdministrarCatalogo([FromBody] JsonElement body)
        {
            var datos = JsonSerializer.Deserialize<Dictionary<string, object?>>(body.GetRawText()) ?? [];
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

        private async Task<IActionResult> Ejecutar(Func<Task<List<JsonElement>>> accion)
        {
            try
            {
                var resultado = await accion();
                return Ok(resultado);
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
