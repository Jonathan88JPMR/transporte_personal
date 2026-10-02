using api_transporte_personal.Infraestructure.Persistence;
using System.Data.Common;
using System.Data;
using Microsoft.EntityFrameworkCore;
using System.Text.Json;
using System.Text;

namespace api_transporte_personal.Infraestructure.RepositoryImpl
{
    public abstract class BaseRepository
    {
        protected readonly ApplicationDbContext _context;

        public BaseRepository(ApplicationDbContext context)
        {
            _context = context;
        }

        protected async Task<List<T>> EjecutarStoredProcedureAsync<T>(
            string spName,
            string? json,
            Func<DbDataReader, T> mapeo,
            bool parametrosRequeridos = false)
        {
            var lista = new List<T>();
            var command = _context.Database.GetDbConnection().CreateCommand();
            command.CommandText = spName;
            command.CommandType = CommandType.StoredProcedure;

            if (parametrosRequeridos && !string.IsNullOrEmpty(json))
            {
                var param = command.CreateParameter();
                param.ParameterName = "@json";
                param.DbType = DbType.String;
                param.Value = json;
                command.Parameters.Add(param);
            }

            try
            {
                await _context.Database.OpenConnectionAsync();
                using (var result = await command.ExecuteReaderAsync())
                {
                    while (await result.ReadAsync())
                    {
                        lista.Add(mapeo(result));
                    }
                }
            }
            finally
            {
                await _context.Database.CloseConnectionAsync();
            }

            return lista;
        }

        protected async Task<int> EjecutarQueryAsync(string sql, Action<DbCommand> parametros)
        {
            var command = _context.Database.GetDbConnection().CreateCommand();
            command.CommandText = sql;
            command.CommandType = CommandType.Text;

            parametros(command);

            try
            {
                await _context.Database.OpenConnectionAsync();
                int affectedRows = await command.ExecuteNonQueryAsync();
                return affectedRows;
            }
            finally
            {
                await _context.Database.CloseConnectionAsync();
            }
        }

        protected async Task<List<JsonElement>> ExecuteStoredProcedureAsync(string spName, string json)
        {
            return await EjecutarStoredProcedureAsync(spName, json, result =>
            {
                var jsonString = result.GetString(0);
                return JsonSerializer.Deserialize<JsonElement>(jsonString);
            }, true);
        }

        protected async Task<List<JsonElement>> ExecuteStoredProcedureWithJsonArrayAsync(string spName, string json, int commandTimeout = 120)
        {
            var jsonBuilder = new StringBuilder();

            var command = _context.Database.GetDbConnection().CreateCommand();
            command.CommandText = spName;
            command.CommandType = CommandType.StoredProcedure;
            command.CommandTimeout = commandTimeout;

            if (!string.IsNullOrEmpty(json))
            {
                var param = command.CreateParameter();
                param.ParameterName = "@json";
                param.DbType = DbType.String;
                param.Value = json;
                command.Parameters.Add(param);
            }

            Guid? idOperacion = null;
            try
            {
                using var document = JsonDocument.Parse(string.IsNullOrWhiteSpace(json) ? "{}" : json);
                if (document.RootElement.TryGetProperty("idOperacion", out var value) && Guid.TryParse(value.GetString(), out var parsedId)) idOperacion = parsedId;
            }
            catch (JsonException) { }

            try
            {
                await _context.Database.OpenConnectionAsync();
                if (idOperacion.HasValue)
                {
                    using var verification = _context.Database.GetDbConnection().CreateCommand();
                    verification.CommandText = "SELECT COUNT(*) FROM TP_OPERACIONES_CLIENTE WHERE idOperacion=@id";
                    var parameter = verification.CreateParameter();
                    parameter.ParameterName = "@id";
                    parameter.Value = idOperacion.Value;
                    verification.Parameters.Add(parameter);
                    if (Convert.ToInt32(await verification.ExecuteScalarAsync()) > 0) return [];
                }
                using (var result = await command.ExecuteReaderAsync())
                {
                    while (await result.ReadAsync())
                    {
                        // FOR JSON PATH parte el resultado en chunks de ~2033 chars
                        // Concatenar todas las filas para reconstruir el JSON completo
                        if (!result.IsDBNull(0))
                            jsonBuilder.Append(result.GetString(0));
                    }
                }
                if (idOperacion.HasValue)
                {
                    using var registration = _context.Database.GetDbConnection().CreateCommand();
                    registration.CommandText = "INSERT INTO TP_OPERACIONES_CLIENTE(idOperacion) VALUES(@id)";
                    var parameter = registration.CreateParameter();
                    parameter.ParameterName = "@id";
                    parameter.Value = idOperacion.Value;
                    registration.Parameters.Add(parameter);
                    await registration.ExecuteNonQueryAsync();
                }
            }
            finally
            {
                await _context.Database.CloseConnectionAsync();
            }

            var fullJson = jsonBuilder.ToString();
            if (string.IsNullOrWhiteSpace(fullJson))
                fullJson = "[]";

            var parsed = JsonSerializer.Deserialize<JsonElement>(fullJson);
            return new List<JsonElement> { parsed };
        }
    }
}
