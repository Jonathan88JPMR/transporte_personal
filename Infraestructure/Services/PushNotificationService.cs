using Microsoft.Data.SqlClient;
using System.Text.Json;
using WebPush;

namespace api_transporte_personal.Infraestructure.Services
{
    // Envía notificaciones Web Push reales (service worker) a los
    // dispositivos suscritos de los conductores. Se dispara tras cada
    // asignación del coordinador; el polling de la app sigue como respaldo.
    public class PushNotificationService
    {
        private readonly string _connectionString;
        private readonly ILogger<PushNotificationService> _logger;
        private readonly VapidDetails? _vapid;

        public PushNotificationService(IConfiguration configuration, ILogger<PushNotificationService> logger)
        {
            _connectionString = configuration.GetConnectionString("DefaultConnection")!;
            _logger = logger;
            var publica = configuration["WebPush:PublicKey"];
            var privada = configuration["WebPush:PrivateKey"];
            if (!string.IsNullOrWhiteSpace(publica) && !string.IsNullOrWhiteSpace(privada))
            {
                _vapid = new VapidDetails(
                    configuration["WebPush:Subject"] ?? "mailto:soporte@agroapps.net",
                    publica, privada);
            }
        }

        public bool Configurado => _vapid != null;
        public string? ClavePublica => _vapid?.PublicKey;

        // Extrae las placas del resultado de un SP de asignación (solicitud,
        // traslado o porciones multi-unidad) y envía push a los conductores.
        // Solo se envía cuando el servicio es del día (regla "alertas de hoy").
        // Se invoca fire-and-forget: nunca bloquea ni rompe la respuesta.
        public async Task EnviarAsignacionAsync(List<JsonElement> resultado)
        {
            try
            {
                if (!Configurado) return;
                var datos = ExtraerDatos(resultado);
                if (!datos.Placas.Any()) return;
                if (!await EsDelDiaAsync(datos)) return;
                await EnviarPorPlacasAsync(datos.Placas.Distinct().ToList());
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Push - Error enviando notificación de asignación");
            }
        }

        private static DatosAsignacion ExtraerDatos(IEnumerable<JsonElement> elementos)
        {
            var d = new DatosAsignacion();
            foreach (var el in elementos)
            {
                var items = el.ValueKind == JsonValueKind.Array ? el.EnumerateArray() : Enumerable.Empty<JsonElement>().Append(el);
                foreach (var item in items)
                {
                    if (item.ValueKind != JsonValueKind.Object) continue;
                    if (item.TryGetProperty("placa", out var p) && p.ValueKind == JsonValueKind.String)
                    {
                        var placa = p.GetString();
                        if (!string.IsNullOrWhiteSpace(placa) && placa != "MULTIPLE")
                            d.Placas.Add(placa);
                    }
                    if (item.TryGetProperty("idSolicitud", out var s) && s.ValueKind == JsonValueKind.Number)
                        d.IdsSolicitud.Add(s.GetInt32());
                    if (item.TryGetProperty("idTraslado", out var t) && t.ValueKind == JsonValueKind.Number)
                        d.IdsTraslado.Add(t.GetInt32());
                    if (item.TryGetProperty("fechaProgramada", out var f) && f.ValueKind == JsonValueKind.String
                        && DateTime.TryParse(f.GetString(), out var fecha))
                        d.FechasDirectas.Add(fecha.Date);
                }
            }
            return d;
        }

        // "Solo del día": la fecha programada del servicio debe ser hoy.
        // La hora oficial es la del servidor de BD (CAST(GETDATE() AS DATE)).
        private async Task<bool> EsDelDiaAsync(DatosAsignacion d)
        {
            if (d.FechasDirectas.Any(f => f == DateTime.Today)) return true;
            if (!d.IdsSolicitud.Any() && !d.IdsTraslado.Any()) return false;
            var condiciones = new List<string>();
            if (d.IdsSolicitud.Any()) condiciones.Add($"idSolicitud IN ({string.Join(",", d.IdsSolicitud.Distinct())})");
            if (d.IdsTraslado.Any()) condiciones.Add($"idTraslado IN ({string.Join(",", d.IdsTraslado.Distinct())})");
            using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync();
            using var cmd = new SqlCommand(
                $@"SELECT COUNT(*) FROM TP_SOLICITUDES
                   WHERE CAST(fechaProgramada AS DATE) = CAST(GETDATE() AS DATE)
                     AND ({string.Join(" OR ", condiciones)})", conn);
            return Convert.ToInt32(await cmd.ExecuteScalarAsync()) > 0;
        }

        private class DatosAsignacion
        {
            public List<string> Placas { get; } = [];
            public List<int> IdsSolicitud { get; } = [];
            public List<int> IdsTraslado { get; } = [];
            public List<DateTime> FechasDirectas { get; } = [];
        }

        private async Task EnviarPorPlacasAsync(List<string> placas)
        {
            var suscripciones = await SuscripcionesDePlacasAsync(placas);
            if (!suscripciones.Any()) return;

            var cliente = new WebPushClient();
            foreach (var sub in suscripciones)
            {
                var payload = JsonSerializer.Serialize(new
                {
                    notification = new
                    {
                        title = "Nuevo servicio asignado",
                        body = $"Tienes un viaje asignado a la unidad {sub.Placa}. Toca para ver tus servicios.",
                        icon = "icons/icon-192.png",
                        badge = "icons/icon-72.png",
                        vibrate = new[] { 300, 120, 300, 120, 300 },
                        tag = $"asignacion-{sub.Placa}",
                        renotify = true,
                        data = new
                        {
                            onActionClick = new
                            {
                                @default = new { operation = "navigateLastFocusedOrOpen", url = "/#/main/conductor" }
                            }
                        }
                    }
                });
                try
                {
                    await cliente.SendNotificationAsync(
                        new PushSubscription(sub.Endpoint, sub.P256dh, sub.Auth), payload, _vapid);
                }
                catch (WebPushException ex) when (ex.StatusCode is System.Net.HttpStatusCode.NotFound
                                               or System.Net.HttpStatusCode.Gone)
                {
                    // Suscripción muerta en el navegador: se limpia de la BD
                    await EliminarEndpointAsync(sub.Endpoint);
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex, "Push - Falló envío a {Endpoint}", sub.Endpoint);
                }
            }
        }

        private async Task<List<SuscripcionPush>> SuscripcionesDePlacasAsync(List<string> placas)
        {
            var lista = new List<SuscripcionPush>();
            using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync();
            var parametros = string.Join(",", placas.Select((_, i) => $"@p{i}"));
            using var cmd = new SqlCommand(
                $@"SELECT u.placa, s.endpoint, s.p256dh, s.auth
                   FROM TP_PUSH_SUSCRIPCIONES s
                   JOIN TP_USUARIOS u ON u.idUsuario = s.idUsuario
                   WHERE u.placa IN ({parametros}) AND u.activo = 1", conn);
            for (var i = 0; i < placas.Count; i++)
                cmd.Parameters.AddWithValue($"@p{i}", placas[i]);
            using var reader = await cmd.ExecuteReaderAsync();
            while (await reader.ReadAsync())
                lista.Add(new SuscripcionPush(reader.GetString(0), reader.GetString(1), reader.GetString(2), reader.GetString(3)));
            return lista;
        }

        private async Task EliminarEndpointAsync(string endpoint)
        {
            using var conn = new SqlConnection(_connectionString);
            await conn.OpenAsync();
            using var cmd = new SqlCommand("DELETE FROM TP_PUSH_SUSCRIPCIONES WHERE endpoint = @e", conn);
            cmd.Parameters.AddWithValue("@e", endpoint);
            await cmd.ExecuteNonQueryAsync();
        }

        private record SuscripcionPush(string Placa, string Endpoint, string P256dh, string Auth);
    }
}
