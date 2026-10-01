using System.Security.Claims;
using ClientHealthApi.Data;
using ClientHealthApi.Converters;
using ClientHealthApi.Models;
using Microsoft.AspNetCore.Authentication.Negotiate;
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

// Authentication:Mode = Negotiate (default) or None. None accepts unauthenticated callers.
var authenticationMode = builder.Configuration["Authentication:Mode"] ?? "Negotiate";
var requireAuthentication = !string.Equals(authenticationMode, "None", StringComparison.OrdinalIgnoreCase);
var adminGroup = builder.Configuration["Authentication:AdminGroup"];
if (string.IsNullOrWhiteSpace(adminGroup)) { adminGroup = @"BUILTIN\Administrators"; }

if (requireAuthentication)
{
    builder.Services.AddAuthentication(NegotiateDefaults.AuthenticationScheme).AddNegotiate();
    builder.Services.AddAuthorization(options =>
    {
        options.AddPolicy("Reporter", policy => policy.RequireAuthenticatedUser());
        options.AddPolicy("Admin", policy => policy.RequireAuthenticatedUser().RequireRole(adminGroup));
    });
}

// Logging
builder.Logging.AddConsole();

var app = builder.Build();

if (requireAuthentication)
{
    app.UseAuthentication();
    app.UseAuthorization();
}
else
{
    app.Logger.LogWarning("Authentication:Mode is None. Any caller can read, change, or delete client records.");
}

// A computer account (DOMAIN\HOST$) may write only its own row. Members of the admin group may write any row.
bool MayWrite(ClaimsPrincipal user, string hostname)
{
    if (!requireAuthentication) { return true; }
    if (user.IsInRole(adminGroup)) { return true; }
    var account = user.Identity?.Name ?? "";
    var samAccountName = account.Contains('\\') ? account[(account.LastIndexOf('\\') + 1)..] : account;
    return samAccountName.EndsWith('$') &&
           string.Equals(samAccountName.TrimEnd('$'), hostname, StringComparison.OrdinalIgnoreCase);
}

RouteHandlerBuilder Secure(RouteHandlerBuilder route, string policy) =>
    requireAuthentication ? route.RequireAuthorization(policy) : route;

// Health check endpoint
app.MapGet("/", () => Results.Ok(new { Status = "OK", Version = "0.8.4", Timestamp = DateTime.UtcNow }));

// GET /api/Clients/{hostname}
Secure(app.MapGet("/api/Clients/{hostname}", async (string hostname, ClientHealthDbContext db) =>
{
    var client = await db.Clients.FindAsync(hostname.Trim());
    return client is not null ? Results.Ok(client) : Results.NotFound();
}), "Admin");

// GET /api/Clients (all clients, paginated)
Secure(app.MapGet("/api/Clients", async (ClientHealthDbContext db, int? skip, int? take) =>
{
    var offset = Math.Max(skip ?? 0, 0);
    var limit = Math.Clamp(take ?? 1000, 1, 1000);
    var clients = await db.Clients.OrderBy(c => c.Hostname).Skip(offset).Take(limit).ToListAsync();
    return Results.Ok(clients);
}), "Admin");

// POST /api/Clients (create or update)
Secure(app.MapPost("/api/Clients", async (Client client, ClientHealthDbContext db, ClaimsPrincipal user) =>
{
    ClientNormalizer.Normalize(client);
    if (string.IsNullOrWhiteSpace(client.Hostname))
        return Results.BadRequest("Hostname is required");
    if (!MayWrite(user, client.Hostname))
        return Results.Forbid();

    // Timestamp follows the client's Logging.TimeFormat, the same value the direct SQL path writes.
    client.Timestamp ??= DateTime.UtcNow;

    for (var attempt = 1; ; attempt++)
    {
        var existing = await db.Clients.FindAsync(client.Hostname);
        if (existing is not null)
        {
            // The key lookup ignores case and trailing spaces; EF refuses to change a tracked key value.
            client.Hostname = existing.Hostname;
            // A run that did not install the client sends no install time; keep the last one.
            client.ClientInstalled ??= existing.ClientInstalled;
            db.Entry(existing).CurrentValues.SetValues(client);
        }
        else
        {
            db.Clients.Add(client);
        }

        try
        {
            await db.SaveChangesAsync();
            return Results.Ok(client);
        }
        catch (DbUpdateException) when (existing is null && attempt == 1)
        {
            // A concurrent POST inserted the same hostname first; retry as an update.
            db.ChangeTracker.Clear();
        }
    }
}), "Reporter");

// PUT /api/Clients/{hostname} (update existing)
Secure(app.MapPut("/api/Clients/{hostname}", async (string hostname, Client client, ClientHealthDbContext db, ClaimsPrincipal user) =>
{
    ClientNormalizer.Normalize(client);
    if (!string.Equals(hostname.Trim(), client.Hostname, StringComparison.OrdinalIgnoreCase))
        return Results.BadRequest("Hostname in URL does not match body");
    if (!MayWrite(user, client.Hostname))
        return Results.Forbid();

    var existing = await db.Clients.FindAsync(client.Hostname);
    if (existing is null)
        return Results.NotFound();

    client.Hostname = existing.Hostname;
    client.Timestamp ??= DateTime.UtcNow;
    client.ClientInstalled ??= existing.ClientInstalled;
    db.Entry(existing).CurrentValues.SetValues(client);
    await db.SaveChangesAsync();
    return Results.Ok(existing);
}), "Reporter");

// DELETE /api/Clients/{hostname} (admin cleanup)
Secure(app.MapDelete("/api/Clients/{hostname}", async (string hostname, ClientHealthDbContext db) =>
{
    var client = await db.Clients.FindAsync(hostname.Trim());
    if (client is null) return Results.NotFound();

    db.Clients.Remove(client);
    await db.SaveChangesAsync();
    return Results.NoContent();
}), "Admin");

app.Run();
