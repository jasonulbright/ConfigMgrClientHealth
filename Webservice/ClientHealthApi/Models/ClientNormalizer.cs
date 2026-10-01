using System.ComponentModel.DataAnnotations;
using System.Reflection;

namespace ClientHealthApi.Models;

public static class ClientNormalizer
{
    private static readonly DateTime SmallDateTimeMin = new(1900, 1, 1);
    private static readonly DateTime SmallDateTimeMax = new(2079, 6, 6);

    private static readonly (PropertyInfo Property, int MaxLength)[] StringProperties =
        typeof(Client).GetProperties()
            .Where(p => p.PropertyType == typeof(string) && p.GetCustomAttribute<MaxLengthAttribute>() is not null)
            .Select(p => (p, p.GetCustomAttribute<MaxLengthAttribute>()!.Length))
            .ToArray();

    private static readonly PropertyInfo[] SmallDateTimeProperties =
        typeof(Client).GetProperties()
            .Where(p => p.PropertyType == typeof(DateTime?) && p.Name != nameof(Client.Timestamp))
            .ToArray();

    // SQL Server rejects the whole row for one over-length string, an out-of-range smalldatetime,
    // or a NULL in a NOT NULL column. Clients cannot fix any of these, so the row is repaired here.
    public static void Normalize(Client client)
    {
        client.Hostname = (client.Hostname ?? "").Trim();

        foreach (var (property, maxLength) in StringProperties)
        {
            if (property.GetValue(client) is string value && value.Length > maxLength)
            {
                property.SetValue(client, value[..maxLength]);
            }
        }

        foreach (var property in SmallDateTimeProperties)
        {
            if (property.GetValue(client) is DateTime value && (value < SmallDateTimeMin || value > SmallDateTimeMax))
            {
                property.SetValue(client, null);
            }
        }

        client.OperatingSystem = string.IsNullOrWhiteSpace(client.OperatingSystem) ? "Unknown" : client.OperatingSystem;
        client.Architecture = string.IsNullOrWhiteSpace(client.Architecture) ? "Unknown" : client.Architecture;
        client.Build = string.IsNullOrWhiteSpace(client.Build) ? "Unknown" : client.Build;
    }
}
