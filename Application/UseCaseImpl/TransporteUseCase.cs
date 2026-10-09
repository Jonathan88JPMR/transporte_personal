using api_transporte_personal.Domain.Repository;
using api_transporte_personal.Domain.UseCase;
using System.Text.Json;

namespace api_transporte_personal.Application.UseCaseImpl
{
    public class TransporteUseCase : ITransporteUseCase
    {
        private readonly ITransporteRepository _repo;
        private readonly ILogger<TransporteUseCase> _logger;

        public TransporteUseCase(ITransporteRepository repo, ILogger<TransporteUseCase> logger)
        {
            _repo = repo;
            _logger = logger;
        }

        // Solicitudes
        public async Task<List<JsonElement>> ListarSolicitudesAsync(string json)
        {
            _logger.LogInformation("UseCase - Listando solicitudes de transporte");
            return await _repo.ListarSolicitudesAsync(json);
        }

        public async Task<List<JsonElement>> GuardarSolicitudAsync(string json)
        {
            _logger.LogInformation("UseCase - Guardando solicitud de transporte");
            return await _repo.GuardarSolicitudAsync(json);
        }

        public async Task<List<JsonElement>> EliminarSolicitudAsync(string json)
        {
            _logger.LogInformation("UseCase - Eliminando solicitud de transporte");
            return await _repo.EliminarSolicitudAsync(json);
        }

        public async Task<List<JsonElement>> MarcarRealizadoAsync(string json)
        {
            _logger.LogInformation("UseCase - Marcando solicitud como realizada");
            return await _repo.MarcarRealizadoAsync(json);
        }

        public async Task<List<JsonElement>> CambiarEstadoAsync(string json)
        {
            _logger.LogInformation("UseCase - Cambiando estado de solicitud");
            return await _repo.CambiarEstadoAsync(json);
        }

        // Asignación y agrupación de traslados
        public async Task<List<JsonElement>> AsignarUnidadAsync(string json)
        {
            _logger.LogInformation("UseCase - Asignando unidad a solicitud");
            return await _repo.AsignarUnidadAsync(json);
        }

        public async Task<List<JsonElement>> DesasignarUnidadAsync(string json)
        {
            _logger.LogInformation("UseCase - Desasignando unidad de solicitud");
            return await _repo.DesasignarUnidadAsync(json);
        }

        public async Task<List<JsonElement>> UnirSolicitudesAsync(string json)
        {
            _logger.LogInformation("UseCase - Uniendo solicitudes en un solo traslado");
            return await _repo.UnirSolicitudesAsync(json);
        }

        public async Task<List<JsonElement>> SepararSolicitudAsync(string json)
        {
            _logger.LogInformation("UseCase - Separando solicitud de su traslado");
            return await _repo.SepararSolicitudAsync(json);
        }

        // Conductor
        public async Task<List<JsonElement>> ListarServiciosConductorAsync(string json)
        {
            _logger.LogInformation("UseCase - Listando servicios del conductor");
            return await _repo.ListarServiciosConductorAsync(json);
        }

        public async Task<List<JsonElement>> ListarTrasladosAsync(string json)
        {
            _logger.LogInformation("UseCase - Listando traslados");
            return await _repo.ListarTrasladosAsync(json);
        }

        public async Task<List<JsonElement>> AgregarPasajerosAsync(string json)
        {
            _logger.LogInformation("UseCase - Agregando pasajeros de emergencia");
            return await _repo.AgregarPasajerosAsync(json);
        }

        // Catálogos
        public async Task<List<JsonElement>> ListarPuntosAsync(string json)
        {
            _logger.LogInformation("UseCase - Listando puntos");
            return await _repo.ListarPuntosAsync(json);
        }

        public async Task<List<JsonElement>> ListarUnidadesAsync(string json)
        {
            _logger.LogInformation("UseCase - Listando unidades");
            return await _repo.ListarUnidadesAsync(json);
        }

        public async Task<List<JsonElement>> ListarMotivosAsync(string json)
        {
            _logger.LogInformation("UseCase - Listando motivos");
            return await _repo.ListarMotivosAsync(json);
        }

        // Reportes
        public async Task<List<JsonElement>> ReporteSolicitudesAsync(string json)
        {
            _logger.LogInformation("UseCase - Generando reporte de solicitudes");
            return await _repo.ReporteSolicitudesAsync(json);
        }

        public Task<List<JsonElement>> GuardarParadasAsync(string json) => _repo.GuardarParadasAsync(json);
        public Task<List<JsonElement>> AcoplarSolicitudAsync(string json) => _repo.AcoplarSolicitudAsync(json);
        public Task<List<JsonElement>> AsignarMultiplesUnidadesAsync(string json) => _repo.AsignarMultiplesUnidadesAsync(json);
        public Task<List<JsonElement>> AdministrarCatalogoAsync(string json) => _repo.AdministrarCatalogoAsync(json);
        public Task<List<JsonElement>> ReporteIndicadoresAsync(string json) => _repo.ReporteIndicadoresAsync(json);
        public Task<List<JsonElement>> ListarAuditoriaAsync(string json) => _repo.ListarAuditoriaAsync(json);
        public Task<List<JsonElement>> ListarNotificacionesAsync(string json) => _repo.ListarNotificacionesAsync(json);
        public Task<List<JsonElement>> MarcarNotificacionAsync(string json) => _repo.MarcarNotificacionAsync(json);

        // Seguimiento de paradas
        public Task<List<JsonElement>> ParadaLlegadaAsync(string json) => _repo.ParadaLlegadaAsync(json);
        public Task<List<JsonElement>> ParadaRegistrarAsync(string json) => _repo.ParadaRegistrarAsync(json);
        public Task<List<JsonElement>> ParadaOmitirAsync(string json) => _repo.ParadaOmitirAsync(json);
        public Task<List<JsonElement>> ParadaImprevistaAsync(string json) => _repo.ParadaImprevistaAsync(json);
        public Task<List<JsonElement>> TrasladoProgresoAsync(string json) => _repo.TrasladoProgresoAsync(json);
        public Task<List<JsonElement>> ReportarUbicacionAsync(string json) => _repo.ReportarUbicacionAsync(json);
    }
}
