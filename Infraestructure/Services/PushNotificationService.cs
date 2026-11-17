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
        // Se invoca fire-and-forget: nunca bloquea ni rompe la respuesta.
        public async Task EnviarAsignacionAsync(List<JsonElement> resultado)
        {
            try
            {
                if (!Configurado) return;
                var placas = ExtraerPlacas(resultado).ToList();
                if (!placas.Any()) return;
                await EnviarPorPlacasAsync(placas);
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Push - Error enviando notificación de asignación");
            }
        }

        private static IEnumerable<string> ExtraerPlacas(IEnumerable<JsonElement> elementos)
        {
            foreach (var el in elementos)
            {
                var items = el.ValueKind == JsonValueKind.Array ? el.EnumerateArray() : Enumerable.Empty<JsonElement>().Append(el);
                foreach (var item in items)
                {
                    if (item.ValueKind == JsonValueKind.Object
                        && item.TryGetProperty("placa", out var p)
                        && p.ValueKind == JsonValueKind.String)
                    {
                        var placa = p.GetString();
                        if (!string.IsNullOrWhiteSpace(placa) && placa != "MULTIPLE")
                            yield return placa;
                    }
                }
            }
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
