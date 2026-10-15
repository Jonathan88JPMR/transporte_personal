using System.Net.Http.Json;
using System.Text.Json;

namespace api_transporte_personal.Infraestructure.Services
{
    public class LogisticaOptions
    {
        public string BaseUrl { get; set; } = string.Empty;
        public string IngresarTransportePath { get; set; } = "/api/logistica/orden-servicio/ingresar-transporte";
        public string ConsultaEstadoPath { get; set; } = "/api/logistica/orden-servicio/obtener-por-id";
        public bool MockHabilitado { get; set; }
    }

    public record ResultadoMigracion(bool Ok, string? NumeroOS, string Respuesta, string? Error);
    public record ResultadoEstadoOS(bool Ok, string? NumeroOSSpring, string? EstadoLogistica, string? Error);

    // Cliente del endpoint de logística que recibe órdenes de servicio de transporte
    // (api/logistica/orden-servicio/ingresar-transporte). En desarrollo apunta al mock local.
    public class LogisticaClient
    {
        private readonly HttpClient _http;
        private readonly LogisticaOptions _options;

        public LogisticaClient(HttpClient http, IConfiguration configuration)
        {
            _http = http;
            _options = configuration.GetSection("Logistica").Get<LogisticaOptions>() ?? new LogisticaOptions();
        }

        public LogisticaOptions Options => _options;

        // Envía la OS de transporte a logística. El payload lo arma el SP
        // TRANSPORTE_generarOS con el contrato de orden-servicio/ingresar-transporte:
        //   {idempresa, ruc_empresa, ruc_transportista, total_viajes, total_tarifa,
        //    igv_total_tarifa, fechaProceso, usuario (DNI del supervisor firmante),
        //    fechaInicioServicio, fechaFinServicio,
        //    detalle:[{ruc_transportista, idcultivo, idproyecto, ceco, TotalHoras,
        //              idlabor, cuenta, codfundo, costo}]}
        // Devuelve el numeroOS que logística le asigna (queda en numeroOSExterno).
        public async Task<ResultadoMigracion> IngresarTransporteAsync(JsonElement payload, CancellationToken ct = default)
        {
            var url = $"{_options.BaseUrl.TrimEnd('/')}{_options.IngresarTransportePath}";
            try
            {
                var respuesta = await _http.PostAsJsonAsync(url, payload, ct);
                var texto = await respuesta.Content.ReadAsStringAsync(ct);
                if (!respuesta.IsSuccessStatusCode)
                    return new ResultadoMigracion(false, null, texto, $"HTTP {(int)respuesta.StatusCode}");

                string? numeroOS = null;
                var ok = true;
                try
                {
                    var doc = JsonDocument.Parse(texto).RootElement;
                    if (doc.ValueKind == JsonValueKind.Array && doc.GetArrayLength() > 0) doc = doc[0];
                    if (doc.TryGetProperty("success", out var s) && s.ValueKind == JsonValueKind.False) ok = false;
                    foreach (var clave in new[] { "numeroOS", "numeroOrden", "numero_os" })
                        if (doc.TryGetProperty(clave, out var n)) numeroOS = n.ValueKind == JsonValueKind.String ? n.GetString() : n.GetRawText();
                }
                catch { /* respuesta no JSON: se guarda igual */ }
                return new ResultadoMigracion(ok, numeroOS, texto, ok ? null : texto);
            }
            catch (Exception ex)
            {
                return new ResultadoMigracion(false, null, string.Empty, ex.Message);
            }
        }

        // Consulta a logística el estado de una OS ya migrada
        // (orden-servicio/obtener-por-id, body {numeroOrden}) y devuelve el
        // número SPRING si ya fue sincronizada. El parseo es tolerante porque
        // el contrato de respuesta puede variar: desenvuelve {orden|data|[]}
        // y prueba varios nombres de campo para número y estado.
        public async Task<ResultadoEstadoOS> ConsultarEstadoAsync(string numeroOS, CancellationToken ct = default)
        {
            var url = $"{_options.BaseUrl.TrimEnd('/')}{_options.ConsultaEstadoPath}";
            try
            {
                var respuesta = await _http.PostAsJsonAsync(url, new { numeroOrden = numeroOS }, ct);
                var texto = await respuesta.Content.ReadAsStringAsync(ct);
                if (!respuesta.IsSuccessStatusCode)
                    return new ResultadoEstadoOS(false, null, null, $"HTTP {(int)respuesta.StatusCode}");

                var doc = JsonDocument.Parse(texto).RootElement;
                if (doc.ValueKind == JsonValueKind.Array && doc.GetArrayLength() > 0) doc = doc[0];
                // La respuesta puede venir envuelta (orden/data) — se busca el objeto con los datos
                if (doc.TryGetProperty("orden", out var ord) && ord.ValueKind == JsonValueKind.Object) doc = ord;
                else if (doc.TryGetProperty("data", out var dat) && dat.ValueKind == JsonValueKind.Object) doc = dat;
                if (doc.ValueKind == JsonValueKind.Array && doc.GetArrayLength() > 0) doc = doc[0];

                string? numeroSpring = null, estado = null;
                foreach (var clave in new[] { "numeroOrdenSpring", "numeroOrdenSPRING", "numeroSpring" })
                    if (doc.TryGetProperty(clave, out var n) && n.ValueKind == JsonValueKind.String)
                        numeroSpring = n.GetString();
                foreach (var clave in new[] { "estado", "estadoOS", "estadoOrden" })
                    if (doc.TryGetProperty(clave, out var e) && e.ValueKind == JsonValueKind.String)
                        estado = e.GetString();
                return new ResultadoEstadoOS(true, numeroSpring, estado, null);
            }
            catch (Exception ex)
            {
                return new ResultadoEstadoOS(false, null, null, ex.Message);
            }
        }
    }
}
