using Microsoft.Extensions.FileProviders;

var siteRoot = ResolveSiteRoot();
var fileProvider = new PhysicalFileProvider(siteRoot);
var fallbackToRootOnMissing = GetBooleanSetting("DOTNET_FALLBACK_TO_ROOT_ON_MISSING", defaultValue: false);
var statsRootSetting = Environment.GetEnvironmentVariable("DOTNET_STATS_ROOT") ?? "Stats";
var builder = WebApplication.CreateSlimBuilder(args);

builder.WebHost.UseUrls(GetUrls());

var app = builder.Build();

app.MapGet("/healthz", () => Results.Json(new
{
    ok = true,
    framework = "net10.0",
    siteRoot,
    utc = DateTime.UtcNow
}));

app.MapGet("/api/health", () => Results.Json(new
{
    ok = true,
    service = "dotnet",
    port = Environment.GetEnvironmentVariable("DOTNET_PORT") ?? "8010"
}));

app.MapGet("/api/core10/stats/browser", (HttpRequest request) =>
{
    var requestedRoot = request.Query["root"].ToString();
    var requestedYear = request.Query["year"].ToString();
    var resolvedRoot = ResolveStatsRoot(siteRoot, requestedRoot, statsRootSetting);
    var candidates = DiscoverStatsCandidates(siteRoot);
    var hasRoot = resolvedRoot is not null;
    var activePhysicalRoot = resolvedRoot?.PhysicalPath;
    var years = new List<object>();
    var entries = new List<object>();
    string? error = null;

    if (!hasRoot)
    {
        error = "No stats root could be resolved from DOTNET_STATS_ROOT or the requested root.";
    }
    else if (!Directory.Exists(activePhysicalRoot))
    {
        error = $"Stats root not found: {resolvedRoot!.RelativePath}";
    }
    else
    {
        years = Directory
            .GetDirectories(activePhysicalRoot!)
            .Select(path => Path.GetFileName(path))
            .Where(name => !string.IsNullOrWhiteSpace(name))
            .OrderByDescending(name => name)
            .Select(name => new
            {
                name,
                url = $"/api/core10/stats/browser?root={Uri.EscapeDataString(resolvedRoot!.RelativePath)}&year={Uri.EscapeDataString(name)}"
            })
            .Cast<object>()
            .ToList();

        if (!string.IsNullOrWhiteSpace(requestedYear))
        {
            var yearPath = Path.Combine(activePhysicalRoot!, requestedYear);
            if (Directory.Exists(yearPath))
            {
                entries = Directory
                    .GetDirectories(yearPath)
                    .Select(path => BuildStatsEntry(path, resolvedRoot!.WebPath, requestedYear))
                    .OrderBy(entry => entry.SortKey)
                    .Select(entry => new
                    {
                        name = entry.Name,
                        type = entry.Type,
                        reportUrl = entry.ReportUrl,
                        browseUrl = entry.BrowseUrl
                    })
                    .Cast<object>()
                    .ToList();
            }
            else
            {
                error = $"Year folder not found: {requestedYear}";
            }
        }
    }

    return Results.Json(new
    {
        ok = error is null,
        siteRoot,
        configuredRoot = statsRootSetting,
        activeRoot = resolvedRoot?.RelativePath,
        activeRootUrl = resolvedRoot?.WebPath,
        candidates = candidates.Select(candidate => new
        {
            relativePath = candidate.RelativePath,
            webPath = candidate.WebPath
        }),
        years,
        selectedYear = requestedYear,
        entries,
        error
    });
});

app.Use(async (context, next) =>
{
    var topLevelSegment = GetTopLevelSegment(context.Request.Path.Value);
    var reservedLegacyMessage = GetReservedLegacyModuleMessage(topLevelSegment);
    if (reservedLegacyMessage is not null)
    {
        context.Response.StatusCode = StatusCodes.Status404NotFound;
        await context.Response.WriteAsync(reservedLegacyMessage);
        return;
    }

    await next();
});

app.UseDefaultFiles(new DefaultFilesOptions
{
    FileProvider = fileProvider
});

app.UseStaticFiles(new StaticFileOptions
{
    FileProvider = fileProvider
});

app.MapFallback(async context =>
{
    var requestPath = context.Request.Path.Value ?? "/";
    var trimmedPath = requestPath.TrimStart('/');
    var topLevelSegment = GetTopLevelSegment(requestPath);
    var candidatePath = Path.Combine(
        siteRoot,
        trimmedPath.Replace('/', Path.DirectorySeparatorChar)
    );

    var missingLegacyMessage = GetMissingLegacyModuleMessage(topLevelSegment, siteRoot);
    if (missingLegacyMessage is not null)
    {
        context.Response.StatusCode = StatusCodes.Status404NotFound;
        await context.Response.WriteAsync(missingLegacyMessage);
        return;
    }

    if (Directory.Exists(candidatePath))
    {
        if (!requestPath.EndsWith("/", StringComparison.Ordinal))
        {
            var queryString = context.Request.QueryString.HasValue
                ? context.Request.QueryString.Value
                : string.Empty;
            context.Response.Redirect($"{requestPath}/{queryString}", permanent: false);
            return;
        }

        var directoryIndexPath = Path.Combine(candidatePath, "index.html");
        if (File.Exists(directoryIndexPath))
        {
            context.Response.ContentType = "text/html; charset=utf-8";
            await context.Response.SendFileAsync(directoryIndexPath);
            return;
        }
    }

    if (!fallbackToRootOnMissing)
    {
        context.Response.StatusCode = StatusCodes.Status404NotFound;
        await context.Response.WriteAsync("Requested page or file was not found in this webroot.");
        return;
    }

    var indexPath = Path.Combine(siteRoot, "index.html");
    if (!File.Exists(indexPath))
    {
        context.Response.StatusCode = StatusCodes.Status404NotFound;
        await context.Response.WriteAsync("index.html not found in site root.");
        return;
    }

    context.Response.ContentType = "text/html; charset=utf-8";
    await context.Response.SendFileAsync(indexPath);
});

app.Run();

static string ResolveSiteRoot()
{
    var configured = Environment.GetEnvironmentVariable("WEBROOT_SITE_ROOT")
        ?? Environment.GetEnvironmentVariable("DOTNET_SITE_ROOT");

    if (!string.IsNullOrWhiteSpace(configured))
    {
        return Path.GetFullPath(configured);
    }

    return Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", ".."));
}

static string GetUrls()
{
    var urls = Environment.GetEnvironmentVariable("ASPNETCORE_URLS");
    if (!string.IsNullOrWhiteSpace(urls))
    {
        return urls;
    }

    var host = Environment.GetEnvironmentVariable("DOTNET_HOST") ?? "localhost";
    var port = Environment.GetEnvironmentVariable("DOTNET_PORT") ?? "8010";
    return $"http://{host}:{port}";
}

static bool GetBooleanSetting(string key, bool defaultValue)
{
    var raw = Environment.GetEnvironmentVariable(key);
    if (string.IsNullOrWhiteSpace(raw))
    {
        return defaultValue;
    }

    return raw.Trim().ToLowerInvariant() switch
    {
        "1" => true,
        "true" => true,
        "yes" => true,
        "on" => true,
        "0" => false,
        "false" => false,
        "no" => false,
        "off" => false,
        _ => defaultValue
    };
}

static string? GetTopLevelSegment(string? requestPath)
{
    if (string.IsNullOrWhiteSpace(requestPath))
    {
        return null;
    }

    return requestPath
        .TrimStart('/')
        .Split('/', StringSplitOptions.RemoveEmptyEntries)
        .FirstOrDefault();
}

static string? GetReservedLegacyModuleMessage(string? topLevelSegment)
{
    if (string.IsNullOrWhiteSpace(topLevelSegment))
    {
        return null;
    }

    var moduleVersion = topLevelSegment.ToLowerInvariant() switch
    {
        "core" => "4.0",
        "net" => "4.0",
        _ => null
    };

    if (moduleVersion is null)
    {
        return null;
    }

    return $".NET {moduleVersion} module '{topLevelSegment}' is served by the legacy backend on port 8004, not by the shared .NET 10 host.";
}

static string? GetMissingLegacyModuleMessage(string? topLevelSegment, string siteRoot)
{
    if (string.IsNullOrWhiteSpace(topLevelSegment))
    {
        return null;
    }

    var moduleVersion = topLevelSegment.ToLowerInvariant() switch
    {
        "core" => "4.0",
        "net" => "4.0",
        _ => null
    };

    if (moduleVersion is null)
    {
        return null;
    }

    if (Directory.Exists(Path.Combine(siteRoot, topLevelSegment)))
    {
        return null;
    }

    return $".NET {moduleVersion} module '{topLevelSegment}' is not present in this webroot.";
}

static StatsRoot? ResolveStatsRoot(string siteRoot, string? requestedRoot, string configuredRoot)
{
    var effectiveRoot = !string.IsNullOrWhiteSpace(requestedRoot)
        ? requestedRoot
        : configuredRoot;

    if (string.IsNullOrWhiteSpace(effectiveRoot))
    {
        return null;
    }

    return CreateStatsRoot(siteRoot, effectiveRoot);
}

static List<StatsRoot> DiscoverStatsCandidates(string siteRoot)
{
    var results = new List<StatsRoot>();
    var directories = Directory
        .EnumerateDirectories(siteRoot, "*", SearchOption.AllDirectories)
        .Where(path =>
        {
            var name = Path.GetFileName(path);
            if (!name.Equals("Stats", StringComparison.OrdinalIgnoreCase)
                && !name.Equals("stats", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            var relativePath = Path.GetRelativePath(siteRoot, path);
            if (relativePath.StartsWith(".git", StringComparison.OrdinalIgnoreCase)
                || relativePath.Contains($"{Path.DirectorySeparatorChar}.git{Path.DirectorySeparatorChar}", StringComparison.OrdinalIgnoreCase)
                || relativePath.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}", StringComparison.OrdinalIgnoreCase)
                || relativePath.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}", StringComparison.OrdinalIgnoreCase))
            {
                return false;
            }

            return true;
        })
        .OrderBy(path => path, StringComparer.OrdinalIgnoreCase);

    foreach (var directory in directories)
    {
        var root = CreateStatsRoot(siteRoot, Path.GetRelativePath(siteRoot, directory));
        if (root is not null)
        {
            results.Add(root);
        }
    }

    return results
        .GroupBy(item => item.RelativePath, StringComparer.OrdinalIgnoreCase)
        .Select(group => group.First())
        .ToList();
}

static StatsRoot? CreateStatsRoot(string siteRoot, string relativePath)
{
    var normalized = relativePath
        .Replace('\\', '/')
        .Trim();

    if (string.IsNullOrWhiteSpace(normalized))
    {
        return null;
    }

    normalized = normalized.TrimStart('/');
    if (normalized.Contains("../", StringComparison.Ordinal) || normalized == "..")
    {
        return null;
    }

    var combined = Path.GetFullPath(Path.Combine(siteRoot, normalized.Replace('/', Path.DirectorySeparatorChar)));
    if (!combined.StartsWith(siteRoot, StringComparison.Ordinal))
    {
        return null;
    }

    return new StatsRoot(
        normalized,
        combined,
        "/" + normalized.Trim('/'));
}

static StatsEntry BuildStatsEntry(string directoryPath, string rootWebPath, string year)
{
    var name = Path.GetFileName(directoryPath);
    var normalizedRoot = rootWebPath.TrimEnd('/');
    var normalizedYear = year.Trim('/');
    var normalizedName = name.Trim('/');
    var monthPath = $"{normalizedRoot}/{normalizedYear}/{normalizedName}";
    var reportPath = Path.Combine(directoryPath, "all", "123LogReport.htm");
    var reportUrl = File.Exists(reportPath)
        ? $"{monthPath}/all/123LogReport.htm"
        : null;

    var sortKey = int.TryParse(name, out var numericName)
        ? numericName.ToString("D4")
        : name;

    return new StatsEntry(
        name,
        int.TryParse(name, out _) ? "month" : "folder",
        monthPath,
        reportUrl,
        sortKey);
}

record StatsRoot(string RelativePath, string PhysicalPath, string WebPath);
record StatsEntry(string Name, string Type, string BrowseUrl, string? ReportUrl, string SortKey);
