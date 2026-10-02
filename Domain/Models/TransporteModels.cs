namespace api_transporte_personal.Domain.Models
{
    public class UsuarioTransporte
    {
        public int idUsuario { get; set; }
        public string usuario { get; set; } = string.Empty;
        public string claveHash { get; set; } = string.Empty;
        public string nombre { get; set; } = string.Empty;
        public string idrol { get; set; } = string.Empty;
        public string? placa { get; set; }
        public string? area { get; set; }
        public bool activo { get; set; }
        public DateTime fechaCreacion { get; set; }
    }

    public class UnidadTransporte
    {
        public int idUnidad { get; set; }
        public string placa { get; set; } = string.Empty;
        public int capacidad { get; set; }
        public bool activa { get; set; }
    }

    public class PuntoTransporte
    {
        public int idPunto { get; set; }
        public string nombre { get; set; } = string.Empty;
        public bool activo { get; set; }
    }

    public class TrasladoTransporte
    {
        public int idTraslado { get; set; }
        public string placa { get; set; } = string.Empty;
        public string? ruta { get; set; }
        public string estado { get; set; } = "PENDIENTE";
        public DateTime fechaCreacion { get; set; }
    }

    public class SolicitudTransporte
    {
        public int idSolicitud { get; set; }
        public int? idTraslado { get; set; }
        public string nombre { get; set; } = string.Empty;
        public string? area { get; set; }
        public DateOnly fechaProgramada { get; set; }
        public string horaProgramada { get; set; } = string.Empty;
        public string puntoPartida { get; set; } = string.Empty;
        public string puntoLlegada { get; set; } = string.Empty;
        public int cantidad { get; set; }
        public string? motivo { get; set; }
        public string? observacion { get; set; }
        public bool esEmergencia { get; set; }
        public string? placa { get; set; }
        public bool realizado { get; set; }
        public string estado { get; set; } = "PENDIENTE";
        public string? usuarioRegistra { get; set; }
        public DateTime fechaRegistro { get; set; }
    }

    public class LoginRequest
    {
        public string Usuario { get; set; } = string.Empty;
        public string Clave { get; set; } = string.Empty;
    }
}
