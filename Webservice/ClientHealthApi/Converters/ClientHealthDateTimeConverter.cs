using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ClientHealthApi.Converters;

public sealed class ClientHealthDateTimeConverter : JsonConverter<DateTime?>
{
    private static readonly string[] Formats =
    [
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-ddTHH:mm:ss",
        "yyyy-MM-ddTHH:mm:ss.FFFFFFFK",
        "yyyy-MM-ddTHH:mm:ssK",
        "O"
    ];

    public override bool HandleNull => true;

    // Empty or unparseable strings become null. A client that cannot read a date sends
    // "" or 0001-01-01, and either value would otherwise fail the whole row at SQL Server.
    public override DateTime? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options)
    {
        if (reader.TokenType == JsonTokenType.Null) { return null; }
        if (reader.TokenType != JsonTokenType.String) { throw new JsonException($"Expected a date string, got {reader.TokenType}."); }

        var value = reader.GetString();
        if (string.IsNullOrWhiteSpace(value)) { return null; }

        const DateTimeStyles styles = DateTimeStyles.AllowWhiteSpaces | DateTimeStyles.AssumeLocal;
        if (DateTime.TryParseExact(value, Formats, CultureInfo.InvariantCulture, styles, out var exact)) { return exact; }
        if (DateTime.TryParse(value, CultureInfo.InvariantCulture, styles, out var parsed)) { return parsed; }
        return null;
    }

    public override void Write(Utf8JsonWriter writer, DateTime? value, JsonSerializerOptions options)
    {
        if (value.HasValue) { writer.WriteStringValue(value.Value); }
        else { writer.WriteNullValue(); }
    }
}
