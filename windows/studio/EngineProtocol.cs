using System.IO;
using System.Text.Json;

namespace CodexDreamSkinStudio;

internal enum EngineOperation { Preflight, Install, Apply, Status, Pause, Resume, Restore, Verify, Uninstall }
internal enum EngineProgress { Checking, Preparing, Installing, Launching, Connecting, Applying, Verifying, Pausing, Restoring, Uninstalling }
internal sealed record EngineState(string Install, string Codex, string Session, string Operation, string? ThemeName, bool RequiresRestart, string[] AvailableActions, bool? Verified);
internal sealed record EngineError(string Code, string Message, string[] RecoveryActions);
internal sealed record EngineEnvelope(int SchemaVersion, bool Ok, string Operation, EngineState State, EngineError? Error);

internal static class EngineOperationExtensions
{
  internal static string ToArgument(this EngineOperation operation) => operation.ToString().ToLowerInvariant();
}

internal static class EngineProtocol
{
  internal static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };
  private static readonly HashSet<string> Operations = Enum.GetNames<EngineOperation>().Select(x => x.ToLowerInvariant()).ToHashSet();
  private static readonly HashSet<string> ProgressValues = Enum.GetNames<EngineProgress>().Select(x => x.ToLowerInvariant()).ToHashSet();
  private static readonly HashSet<string> Installs = ["not-installed", "ready"];
  private static readonly HashSet<string> CodexStates = ["not-installed", "needs-first-run", "stopped", "running"];
  private static readonly HashSet<string> Sessions = ["official", "active", "paused", "stale"];
  private static readonly HashSet<string> StateOperations = ["idle", "busy"];
  private static readonly HashSet<string> Actions = ["install", "apply", "pause", "resume", "restore", "verify", "uninstall"];
  private static readonly HashSet<string> RecoveryActions = ["open-codex", "retry", "cancel", "restore", "diagnostics", "authorize-restart", "authorize-force-stop"];
  private static readonly HashSet<string> ErrorCodes = [
    "INVALID_REQUEST", "OPERATION_BUSY", "CODEX_NOT_INSTALLED", "CODEX_FIRST_RUN_REQUIRED", "CODEX_IDENTITY_INVALID",
    "RUNTIME_INVALID", "CODEX_CLOSE_REQUIRED", "RESTART_REQUIRED", "FORCE_STOP_REQUIRED", "STATE_UNSAFE",
    "PORT_UNAVAILABLE", "CONFIG_UNSAFE", "CONFIG_CHANGED", "CONFIG_BACKUP_MISSING", "THEME_INVALID",
    "INJECTOR_FAILED", "VERIFY_FAILED", "LIVE_REMOVE_FAILED", "OPERATION_FAILED", "INTERNAL_ERROR"
  ];

  internal static EngineEnvelope Parse(string stdout, EngineOperation requestedOperation)
  {
    if (string.IsNullOrEmpty(stdout) || stdout[0] == '\uFEFF') throw new InvalidDataException("The engine response is not valid Protocol v1 output.");

    JsonDocument document;
    try
    {
      document = JsonDocument.Parse(stdout, new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Disallow, AllowTrailingCommas = false });
    }
    catch (JsonException) { throw; }

    using (document)
    {
      var root = document.RootElement;
      RequireObject(root, ["schemaVersion", "ok", "operation", "state", "error"]);
      RequireKind(root, "schemaVersion", JsonValueKind.Number);
      RequireKind(root, "ok", JsonValueKind.True, JsonValueKind.False);
      RequireKind(root, "operation", JsonValueKind.String);
      RequireKind(root, "state", JsonValueKind.Object);
      if (Get(root, "error").ValueKind is not (JsonValueKind.Null or JsonValueKind.Object)) Invalid();

      var state = Get(root, "state");
      RequireObject(state, ["install", "codex", "session", "operation", "themeName", "requiresRestart", "availableActions", "verified"]);
      RequireString(state, "install");
      RequireString(state, "codex");
      RequireString(state, "session");
      RequireString(state, "operation");
      if (Get(state, "themeName").ValueKind is not (JsonValueKind.Null or JsonValueKind.String)) Invalid();
      RequireKind(state, "requiresRestart", JsonValueKind.True, JsonValueKind.False);
      RequireKind(state, "availableActions", JsonValueKind.Array);
      if (Get(state, "verified").ValueKind is not (JsonValueKind.Null or JsonValueKind.True or JsonValueKind.False)) Invalid();

      var error = Get(root, "error");
      if (error.ValueKind == JsonValueKind.Object)
      {
        RequireObject(error, ["code", "message", "recoveryActions"]);
        RequireString(error, "code");
        RequireString(error, "message");
        RequireKind(error, "recoveryActions", JsonValueKind.Array);
        ValidateStringArray(Get(error, "recoveryActions"), RecoveryActions);
        if (Get(error, "code").GetString() is not { } errorCode || !ErrorCodes.Contains(errorCode) ||
            string.IsNullOrWhiteSpace(Get(error, "message").GetString())) Invalid();
      }

      EngineEnvelope envelope;
      try { envelope = JsonSerializer.Deserialize<EngineEnvelope>(root.GetRawText(), JsonOptions) ?? throw new InvalidDataException(); }
      catch (JsonException exception) { throw new InvalidDataException("The engine response is incomplete.", exception); }

      if (envelope.SchemaVersion != 1 ||
          !Operations.Contains(envelope.Operation) ||
          envelope.Operation != requestedOperation.ToArgument() ||
          !Installs.Contains(envelope.State.Install) ||
          !CodexStates.Contains(envelope.State.Codex) ||
          !Sessions.Contains(envelope.State.Session) ||
          !StateOperations.Contains(envelope.State.Operation) ||
          envelope.Ok != (envelope.Error is null)) Invalid();
      ValidateStringArray(Get(state, "availableActions"), Actions);
      if (envelope.State.Operation == "busy" && envelope.State.AvailableActions.Length != 0) Invalid();
      if (envelope.State.Session == "active" && (envelope.State.Install != "ready" || envelope.State.Codex != "running")) Invalid();
      if (envelope.State.Verified == true && envelope.State.Session != "active") Invalid();
      if (envelope.Ok && requestedOperation is EngineOperation.Apply or EngineOperation.Resume or EngineOperation.Verify && envelope.State.Verified != true) Invalid();
      ValidateSemantics(envelope, requestedOperation);
      return envelope;
    }
  }

  internal static void ParseProgress(string stderr, IProgress<EngineProgress>? progress)
  {
    if (stderr.Length == 0) return;
    var normalized = stderr.Replace("\r\n", "\n");
    if (normalized.EndsWith('\n')) normalized = normalized[..^1];
    foreach (var line in normalized.Split('\n'))
    {
      const string prefix = "DREAM_SKIN_PROGRESS ";
      if (line.Length == 0 || !line.StartsWith(prefix, StringComparison.Ordinal) || !ProgressValues.Contains(line[prefix.Length..])) Invalid();
      progress?.Report(Enum.Parse<EngineProgress>(line[prefix.Length..], true));
    }
  }

  private static void RequireObject(JsonElement value, string[] expected)
  {
    if (value.ValueKind != JsonValueKind.Object) Invalid();
    var properties = value.EnumerateObject().ToArray();
    if (properties.Length != expected.Length || properties.Select(x => x.Name).Distinct(StringComparer.OrdinalIgnoreCase).Count() != properties.Length ||
        properties.Any(x => !expected.Contains(x.Name, StringComparer.OrdinalIgnoreCase))) Invalid();
  }

  private static JsonElement Get(JsonElement value, string name)
  {
    foreach (var property in value.EnumerateObject())
      if (property.Name.Equals(name, StringComparison.OrdinalIgnoreCase)) return property.Value;
    Invalid();
    return default;
  }

  private static void RequireKind(JsonElement value, string name, params JsonValueKind[] kinds)
  {
    if (!kinds.Contains(Get(value, name).ValueKind)) Invalid();
  }

  private static void RequireString(JsonElement value, string name)
  {
    RequireKind(value, name, JsonValueKind.String);
    if (Get(value, name).GetString() is not { Length: > 0 }) Invalid();
  }

  private static void ValidateStringArray(JsonElement values, HashSet<string> allowed)
  {
    var seen = new HashSet<string>(StringComparer.Ordinal);
    foreach (var value in values.EnumerateArray())
      if (value.ValueKind != JsonValueKind.String || value.GetString() is not { } text || !allowed.Contains(text) || !seen.Add(text)) Invalid();
  }

  private static void ValidateSemantics(EngineEnvelope envelope, EngineOperation requestedOperation)
  {
    var state = envelope.State;
    var actions = state.AvailableActions;
    var safeUnavailableStatusFailure = !envelope.Ok && requestedOperation is EngineOperation.Preflight or EngineOperation.Status &&
      envelope.Error?.Code == "INTERNAL_ERROR" && envelope.Error.RecoveryActions.SequenceEqual(["retry", "diagnostics", "cancel"]) &&
      state.Install == "not-installed" && state.Codex == "not-installed" && state.Session == "stale" &&
      state.Operation == "idle" && state.ThemeName is null && !state.RequiresRestart && actions.Length == 0 && state.Verified is null;
    var safeUnavailableStatus = requestedOperation is EngineOperation.Preflight or EngineOperation.Status &&
      state.Install == "not-installed" && state.Session == "official" && state.Operation == "idle" &&
      actions.SequenceEqual(["install"]) && state.Verified is null;
    if (state.RequiresRestart && (state.Codex != "running" || state.Session != "official")) Invalid();
    if (state.Session != "official" && state.Install != "ready" && !safeUnavailableStatusFailure) Invalid();
    if (state.Operation == "busy")
    {
      if (envelope.Ok || envelope.Error?.Code != "OPERATION_BUSY" || actions.Length != 0) Invalid();
    }
    else if (envelope.Error?.Code == "OPERATION_BUSY") Invalid();
    if (envelope.Error?.Code == "INVALID_REQUEST" && (state.Install != "not-installed" || state.Codex != "not-installed" ||
        state.Session != "official" || state.Operation != "idle" || state.ThemeName is not null || state.RequiresRestart ||
        state.Verified is not null || actions.Length != 0)) Invalid();

    if (state.Install == "ready")
    {
      if (actions.Contains("install")) Invalid();
    }
    else
    {
      if (actions.Any(action => action != "install") || state.Verified is not null ||
          state.ThemeName is not null && !safeUnavailableStatus) Invalid();
    }
    if (actions.Contains("pause") && state.Session != "active") Invalid();
    if (actions.Contains("resume") && state.Session is not ("active" or "paused")) Invalid();
    if (actions.Contains("apply") && state.Session == "active") Invalid();

    if (!envelope.Ok) return;
    if (state.Install == "not-installed" && requestedOperation is not EngineOperation.Uninstall && !safeUnavailableStatus) Invalid();
    if (state.Operation != "idle") Invalid();
    switch (requestedOperation)
    {
      case EngineOperation.Install when state.Install != "ready":
      case EngineOperation.Pause when state.Session != "paused":
      case EngineOperation.Restore when state.Session != "official":
        Invalid();
        break;
      case EngineOperation.Uninstall when state.Install != "not-installed" || state.Codex != "stopped" ||
        state.Session != "official" || state.ThemeName is not null || state.Verified is not null ||
        !actions.SequenceEqual(["install"]):
        Invalid();
        break;
    }
  }

  private static void Invalid() => throw new InvalidDataException("The engine response violates Protocol v1.");
}
