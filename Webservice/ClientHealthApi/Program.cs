using ClientHealthApi.Data;
using ClientHealthApi.Converters;
using ClientHealthApi.Models;
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);

// Run as Windows Service when installed as one
builder.Host.UseWindowsService();

// Database
builder.Services.AddDbContext<ClientHealthDbContext>(options =>
    options.UseSqlServer(builder.Configuration.GetConnectionString("ClientHealth")));

// Accept legacy client timestamp strings such as "2026-04-30 12:34:56".
builder.Services.ConfigureHttpJsonOptions(options =>
{
    options.SerializerOptions.Converters.Add(new ClientHealthDateTimeConverter());
});

// Logging
builder.Logging.AddConsole();

var app = builder.Build();

// Health check endpoint
app.MapGet("/", () => Results.Ok(new { Status = "OK", Version = "1.0.0", Timestamp = DateTime.UtcNow }));

// GET /api/Clients/{hostname}
app.MapGet("/api/Clients/{hostname}", async (string hostname, ClientHealthDbContext db) =>
{
    var client = await db.Clients.FindAsync(hostname);
    return client is not null ? Results.Ok(client) : Results.NotFound();
});

// GET /api/Clients (all clients, paginated)
app.MapGet("/api/Clients", async (ClientHealthDbContext db, int? skip, int? take) =>
{
    var query = db.Clients.OrderBy(c => c.Hostname).AsQueryable();
    if (skip.HasValue) query = query.Skip(skip.Value);
    var limit = take ?? 1000;
    var clients = await query.Take(limit).ToListAsync();
    return Results.Ok(clients);
});

// POST /api/Clients (create new)
app.MapPost("/api/Clients", async (Client client, ClientHealthDbContext db) =>
{
    if (string.IsNullOrWhiteSpace(client.Hostname))
        return Results.BadRequest("Hostname is required");

    client.Timestamp = DateTime.UtcNow;

    var existing = await db.Clients.FindAsync(client.Hostname);
    if (existing is not null)
    {
        // UPSERT: update existing record
        db.Entry(existing).CurrentValues.SetValues(client);
    }
    else
    {
        db.Clients.Add(client);
    }

    await db.SaveChangesAsync();
    return Results.Ok(client);
});

// PUT /api/Clients/{hostname} (update existing)
app.MapPut("/api/Clients/{hostname}", async (string hostname, Client client, ClientHealthDbContext db) =>
{
    if (!string.Equals(hostname, client.Hostname, StringComparison.OrdinalIgnoreCase))
        return Results.BadRequest("Hostname in URL does not match body");

    var existing = await db.Clients.FindAsync(hostname);
    if (existing is null)
        return Results.NotFound();

    client.Timestamp = DateTime.UtcNow;
    db.Entry(existing).CurrentValues.SetValues(client);
    await db.SaveChangesAsync();
    return Results.Ok(existing);
});

// DELETE /api/Clients/{hostname} (admin cleanup)
app.MapDelete("/api/Clients/{hostname}", async (string hostname, ClientHealthDbContext db) =>
{
    var client = await db.Clients.FindAsync(hostname);
    if (client is null) return Results.NotFound();

    db.Clients.Remove(client);
    await db.SaveChangesAsync();
    return Results.NoContent();
});

app.Run();
