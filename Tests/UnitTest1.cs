using api_transporte_personal.Controllers;
using Microsoft.AspNetCore.Authorization;
using System.Reflection;

namespace api_transporte_personal.Tests;

public class TransporteSecurityTests
{
    [Fact]
    public void ControllerRequiresAuthentication()
    {
        var attribute = typeof(TransporteController).GetCustomAttribute<AuthorizeAttribute>();
        Assert.NotNull(attribute);
    }

    [Fact]
    public void LoginAllowsAnonymousAccess()
    {
        var method = typeof(TransporteController).GetMethod(nameof(TransporteController.Login));
        Assert.NotNull(method?.GetCustomAttribute<AllowAnonymousAttribute>());
    }

    [Theory]
    [InlineData(nameof(TransporteController.GuardarSolicitud), "SPTRANS")]
    [InlineData(nameof(TransporteController.AsignarUnidad), "COTRANS")]
    [InlineData(nameof(TransporteController.ServiciosConductor), "CHTRANS")]
    [InlineData(nameof(TransporteController.AdministrarCatalogo), "ADTRANS")]
    public void ProtectedOperationsRequireExpectedRole(string methodName, string role)
    {
        var method = typeof(TransporteController).GetMethod(methodName);
        var attribute = method?.GetCustomAttribute<AuthorizeAttribute>();
        Assert.NotNull(attribute);
        Assert.Contains(role, attribute!.Roles!.Split(','));
    }
}
