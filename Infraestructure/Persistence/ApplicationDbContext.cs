using Microsoft.EntityFrameworkCore;
using api_transporte_personal.Domain.Models;

namespace api_transporte_personal.Infraestructure.Persistence
{
    public class ApplicationDbContext : DbContext
    {
        public ApplicationDbContext(DbContextOptions<ApplicationDbContext> options) : base(options) { }

        // DbSets para las entidades principales
        public DbSet<UsuarioTransporte> Usuarios { get; set; }
        public DbSet<UnidadTransporte> Unidades { get; set; }
        public DbSet<PuntoTransporte> Puntos { get; set; }
        public DbSet<TrasladoTransporte> Traslados { get; set; }
        public DbSet<SolicitudTransporte> Solicitudes { get; set; }

        protected override void OnModelCreating(ModelBuilder modelBuilder)
        {
            base.OnModelCreating(modelBuilder);

            modelBuilder.Entity<UsuarioTransporte>(entity =>
            {
                entity.ToTable("TP_USUARIOS");
                entity.HasKey(e => e.idUsuario);
                entity.Property(e => e.idUsuario).ValueGeneratedOnAdd();
                entity.Property(e => e.usuario).IsRequired().HasMaxLength(50);
                entity.Property(e => e.claveHash).IsRequired().HasMaxLength(200);
                entity.Property(e => e.nombre).IsRequired().HasMaxLength(200);
                entity.Property(e => e.idrol).IsRequired().HasMaxLength(20);
                entity.Property(e => e.placa).HasMaxLength(20);
            });

            modelBuilder.Entity<UnidadTransporte>(entity =>
            {
                entity.ToTable("TP_UNIDADES");
                entity.HasKey(e => e.idUnidad);
                entity.Property(e => e.idUnidad).ValueGeneratedOnAdd();
                entity.Property(e => e.placa).IsRequired().HasMaxLength(20);
            });

            modelBuilder.Entity<PuntoTransporte>(entity =>
            {
                entity.ToTable("TP_PUNTOS");
                entity.HasKey(e => e.idPunto);
                entity.Property(e => e.idPunto).ValueGeneratedOnAdd();
                entity.Property(e => e.nombre).IsRequired().HasMaxLength(150);
            });

            modelBuilder.Entity<TrasladoTransporte>(entity =>
            {
                entity.ToTable("TP_TRASLADOS");
                entity.HasKey(e => e.idTraslado);
                entity.Property(e => e.idTraslado).ValueGeneratedOnAdd();
                entity.Property(e => e.placa).IsRequired().HasMaxLength(20);
                entity.Property(e => e.ruta).HasMaxLength(1000);
                entity.Property(e => e.estado).HasMaxLength(20);
            });

            modelBuilder.Entity<SolicitudTransporte>(entity =>
            {
                entity.ToTable("TP_SOLICITUDES");
                entity.HasKey(e => e.idSolicitud);
                entity.Property(e => e.idSolicitud).ValueGeneratedOnAdd();
                entity.Property(e => e.nombre).IsRequired().HasMaxLength(200);
                entity.Property(e => e.area).HasMaxLength(100);
                entity.Property(e => e.puntoPartida).IsRequired().HasMaxLength(150);
                entity.Property(e => e.puntoLlegada).IsRequired().HasMaxLength(150);
                entity.Property(e => e.motivo).HasMaxLength(100);
                entity.Property(e => e.placa).HasMaxLength(20);
                entity.Property(e => e.estado).HasMaxLength(20);
                entity.Property(e => e.usuarioRegistra).HasMaxLength(50);
            });
        }
    }
}
