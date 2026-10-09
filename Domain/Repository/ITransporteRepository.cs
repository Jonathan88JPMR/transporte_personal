using System.Text.Json;

namespace api_transporte_personal.Domain.Repository
{
    public interface ITransporteRepository
    {
        // Solicitudes
        Task<List<JsonElement>> ListarSolicitudesAsync(string json);
        Task<List<JsonElement>> GuardarSolicitudAsync(string json);
        Task<List<JsonElement>> EliminarSolicitudAsync(string json);
        Task<List<JsonElement>> MarcarRealizadoAsync(string json);
        Task<List<JsonElement>> CambiarEstadoAsync(string json);

        // Asignación y agrupación de traslados
        Task<List<JsonElement>> AsignarUnidadAsync(string json);
        Task<List<JsonElement>> DesasignarUnidadAsync(string json);
        Task<List<JsonElement>> UnirSolicitudesAsync(string json);
        Task<List<JsonElement>> SepararSolicitudAsync(string json);

        // Conductor
        Task<List<JsonElement>> ListarServiciosConductorAsync(string json);
        Task<List<JsonElement>> ListarTrasladosAsync(string json);
        Task<List<JsonElement>> AgregarPasajerosAsync(string json);

        // Catálogos
        Task<List<JsonElement>> ListarPuntosAsync(string json);
        Task<List<JsonElement>> ListarUnidadesAsync(string json);
        Task<List<JsonElement>> ListarMotivosAsync(string json);

        // Reportes
        Task<List<JsonElement>> ReporteSolicitudesAsync(string json);
        Task<List<JsonElement>> GuardarParadasAsync(string json);
        Task<List<JsonElement>> AcoplarSolicitudAsync(string json);
        Task<List<JsonElement>> AsignarMultiplesUnidadesAsync(string json);
        Task<List<JsonElement>> AdministrarCatalogoAsync(string json);
        Task<List<JsonElement>> ReporteIndicadoresAsync(string json);
        Task<List<JsonElement>> ListarAuditoriaAsync(string json);
        Task<List<JsonElement>> ListarNotificacionesAsync(string json);
        Task<List<JsonElement>> MarcarNotificacionAsync(string json);

        // Seguimiento de paradas
        Task<List<JsonElement>> ParadaLlegadaAsync(string json);
        Task<List<JsonElement>> ParadaRegistrarAsync(string json);
        Task<List<JsonElement>> ParadaOmitirAsync(string json);
        Task<List<JsonElement>> ParadaImprevistaAsync(string json);
        Task<List<JsonElement>> TrasladoProgresoAsync(string json);
        Task<List<JsonElement>> ReportarUbicacionAsync(string json);
    }
}
