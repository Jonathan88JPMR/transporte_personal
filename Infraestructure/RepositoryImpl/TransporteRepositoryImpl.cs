using api_transporte_personal.Domain.Repository;
using api_transporte_personal.Infraestructure.Persistence;
using System.Text.Json;

namespace api_transporte_personal.Infraestructure.RepositoryImpl
{
    public class TransporteRepositoryImpl : BaseRepository, ITransporteRepository
    {
        public TransporteRepositoryImpl(ApplicationDbContext context) : base(context) { }

        // Solicitudes
        public async Task<List<JsonElement>> ListarSolicitudesAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_listarSolicitudes", json);

        public async Task<List<JsonElement>> GuardarSolicitudAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_guardarSolicitud", json);

        public async Task<List<JsonElement>> EliminarSolicitudAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_eliminarSolicitud", json);

        public async Task<List<JsonElement>> MarcarRealizadoAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_marcarRealizado", json);

        public async Task<List<JsonElement>> CambiarEstadoAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_cambiarEstado", json);

        // Asignación y agrupación de traslados
        public async Task<List<JsonElement>> AsignarUnidadAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_asignarUnidad", json);

        public async Task<List<JsonElement>> DesasignarUnidadAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_desasignarUnidad", json);

        public async Task<List<JsonElement>> UnirSolicitudesAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_unirSolicitudes", json);

        public async Task<List<JsonElement>> SepararSolicitudAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_separarSolicitud", json);

        // Conductor
        public async Task<List<JsonElement>> ListarServiciosConductorAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_listarServiciosConductor", json);

        public async Task<List<JsonElement>> ListarTrasladosAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_listarTraslados", json);

        public async Task<List<JsonElement>> AgregarPasajerosAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_agregarPasajeros", json);

        // Catálogos
        public async Task<List<JsonElement>> ListarPuntosAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_listarPuntos", json);

        public async Task<List<JsonElement>> ListarUnidadesAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_listarUnidades", json);

        public async Task<List<JsonElement>> ListarMotivosAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_listarMotivos", json);

        // Reportes
        public async Task<List<JsonElement>> ReporteSolicitudesAsync(string json)
            => await ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_reporteSolicitudes", json);

        public Task<List<JsonElement>> GuardarParadasAsync(string json) => ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_guardarParadas", json);
        public Task<List<JsonElement>> AcoplarSolicitudAsync(string json) => ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_acoplarSolicitud", json);
        public Task<List<JsonElement>> AsignarMultiplesUnidadesAsync(string json) => ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_asignarMultiplesUnidades", json);
        public Task<List<JsonElement>> AdministrarCatalogoAsync(string json) => ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_administrarCatalogo", json);
        public Task<List<JsonElement>> ReporteIndicadoresAsync(string json) => ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_reporteIndicadores", json);
        public Task<List<JsonElement>> ListarAuditoriaAsync(string json) => ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_listarAuditoria", json);
        public Task<List<JsonElement>> ListarNotificacionesAsync(string json) => ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_listarNotificaciones", json);
        public Task<List<JsonElement>> MarcarNotificacionAsync(string json) => ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_marcarNotificacion", json);

        // Seguimiento de paradas
        public Task<List<JsonElement>> ParadaLlegadaAsync(string json) => ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_paradaLlegada", json);
        public Task<List<JsonElement>> ParadaRegistrarAsync(string json) => ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_paradaRegistrar", json);
        public Task<List<JsonElement>> ParadaOmitirAsync(string json) => ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_paradaOmitir", json);
        public Task<List<JsonElement>> ParadaImprevistaAsync(string json) => ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_paradaImprevista", json);
        public Task<List<JsonElement>> TrasladoProgresoAsync(string json) => ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_trasladoProgreso", json);
        public Task<List<JsonElement>> ReportarUbicacionAsync(string json) => ExecuteStoredProcedureWithJsonArrayAsync("TRANSPORTE_reportarUbicacion", json);
    }
}
