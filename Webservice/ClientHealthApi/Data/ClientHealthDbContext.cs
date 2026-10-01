using ClientHealthApi.Models;
using Microsoft.EntityFrameworkCore;

namespace ClientHealthApi.Data;

public class ClientHealthDbContext : DbContext
{
    public ClientHealthDbContext(DbContextOptions<ClientHealthDbContext> options) : base(options) { }

    public DbSet<Client> Clients => Set<Client>();

    // The table uses varchar columns. nvarchar parameters force an implicit conversion of the
    // Hostname primary key, which turns the lookup into a scan under SQL collations.
    protected override void ConfigureConventions(ModelConfigurationBuilder configurationBuilder)
    {
        configurationBuilder.Properties<string>().AreUnicode(false);
    }

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Client>(entity =>
        {
            entity.HasKey(e => e.Hostname);
            entity.ToTable("Clients");
        });
    }
}
