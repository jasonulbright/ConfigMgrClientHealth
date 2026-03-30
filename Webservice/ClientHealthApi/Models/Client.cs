using System.ComponentModel.DataAnnotations;
using System.ComponentModel.DataAnnotations.Schema;

namespace ClientHealthApi.Models;

[Table("Clients")]
public class Client
{
    [Key]
    [MaxLength(100)]
    public string Hostname { get; set; } = "";

    [MaxLength(100)]
    public string? OperatingSystem { get; set; }

    [MaxLength(10)]
    public string? Architecture { get; set; }

    [MaxLength(100)]
    public string? Build { get; set; }

    [MaxLength(100)]
    public string? Manufacturer { get; set; }

    [MaxLength(100)]
    public string? Model { get; set; }

    public DateTime? InstallDate { get; set; }

    public DateTime? OSUpdates { get; set; }

    [MaxLength(100)]
    public string? LastLoggedOnUser { get; set; }

    [MaxLength(100)]
    public string? ClientVersion { get; set; }

    public double PSVersion { get; set; }

    public int PSBuild { get; set; }

    [MaxLength(3)]
    public string? Sitecode { get; set; }

    [MaxLength(100)]
    public string? Domain { get; set; }

    public int MaxLogSize { get; set; }

    public int MaxLogHistory { get; set; }

    public int CacheSize { get; set; }

    [MaxLength(50)]
    public string? ClientCertificate { get; set; }

    [MaxLength(50)]
    public string? ProvisioningMode { get; set; }

    [MaxLength(200)]
    public string? DNS { get; set; }

    [MaxLength(100)]
    public string? Drivers { get; set; }

    [MaxLength(200)]
    public string? Updates { get; set; }

    [MaxLength(50)]
    public string? PendingReboot { get; set; }

    public DateTime? LastBootTime { get; set; }

    public double OSDiskFreeSpace { get; set; }

    [MaxLength(200)]
    public string? Services { get; set; }

    [MaxLength(50)]
    public string? AdminShare { get; set; }

    [MaxLength(50)]
    public string? StateMessages { get; set; }

    [MaxLength(50)]
    public string? WUAHandler { get; set; }

    [MaxLength(50)]
    public string? WMI { get; set; }

    public DateTime? RefreshComplianceState { get; set; }

    public DateTime? ClientInstalled { get; set; }

    [MaxLength(10)]
    public string? Version { get; set; }

    public DateTime? Timestamp { get; set; }

    public DateTime? HWInventory { get; set; }

    [MaxLength(50)]
    public string? SWMetering { get; set; }

    [MaxLength(50)]
    public string? BITS { get; set; }

    public int PatchLevel { get; set; }

    [MaxLength(200)]
    public string? ClientInstalledReason { get; set; }
}
