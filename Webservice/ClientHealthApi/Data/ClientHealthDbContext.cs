using ClientHealthApi.Models;
using Microsoft.EntityFrameworkCore;

namespace ClientHealthApi.Data;

public class ClientHealthDbContext : DbContext
{
    public ClientHealthDbContext(DbContextOptions<ClientHealthDbContext> options) : base(options) { }

    public DbSet<Client> Clients => Set<Client>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<Client>(entity =>
        {
            entity.HasKey(e => e.Hostname);
            entity.ToTable("Clients");
        });
    }
}
