using System.Diagnostics;
using System.IO;
using System.Runtime.ExceptionServices;
using System.Text;

namespace CodexDreamSkinStudio;

internal sealed record EngineProcessResult(int ExitCode, string StandardOutput, string StandardError);

internal interface IEngineProcessRunner
{
  Task<EngineProcessResult> RunAsync(string fileName, IReadOnlyList<string> arguments, IProgress<EngineProgress>? progress, CancellationToken cancellationToken);
}

internal sealed class EngineClient
{
  private readonly IEngineProcessRunner _runner;
  private readonly string _systemRoot;
  private int _busy;

  internal EngineClient() : this(new EngineProcessRunner(), Environment.GetEnvironmentVariable("SystemRoot") ?? throw new InvalidOperationException("SystemRoot is unavailable.")) { }

  internal EngineClient(IEngineProcessRunner runner, string systemRoot)
  {
    _runner = runner;
    _systemRoot = systemRoot;
  }

  internal async Task<EngineEnvelope> RunAsync(
    EngineOperation operation,
    bool restartAuthorized = false,
    bool forceAuthorized = false,
    bool deleteUserThemes = false,
    bool deep = true,
    IProgress<EngineProgress>? progress = null,
    CancellationToken cancellationToken = default)
  {
    if (Interlocked.CompareExchange(ref _busy, 1, 0) != 0) throw new InvalidOperationException("An engine operation is already active.");
    try
    {
      var adapterPath = Path.Combine(AppContext.BaseDirectory, "engine", "scripts", "studio-adapter.ps1");
      var arguments = BuildArguments(operation, adapterPath, restartAuthorized, forceAuthorized, deleteUserThemes, deep);
      var powershell = Path.Combine(_systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
      var result = await _runner.RunAsync(powershell, arguments, progress, cancellationToken);
      if (result.ExitCode is not (0 or 1 or 2)) throw new InvalidDataException("The engine process failed without a domain response.");
      EngineProtocol.ParseProgress(result.StandardError, null);
      var envelope = EngineProtocol.Parse(result.StandardOutput, operation);
      var exitMatches = result.ExitCode switch
      {
        0 => envelope.Ok,
        1 => !envelope.Ok && envelope.Error?.Code != "INVALID_REQUEST",
        2 => !envelope.Ok && envelope.Error?.Code == "INVALID_REQUEST",
        _ => false
      };
      if (!exitMatches) throw new InvalidDataException("The engine exit code does not match its response.");
      return envelope;
    }
    finally { Volatile.Write(ref _busy, 0); }
  }

  internal static IReadOnlyList<string> BuildArguments(
    EngineOperation operation,
    string adapterPath,
    bool restartAuthorized,
    bool forceAuthorized,
    bool deleteUserThemes,
    bool deep)
  {
    if (forceAuthorized && !restartAuthorized) throw new ArgumentException("Force authorization requires restart authorization.");
    if (deleteUserThemes && operation != EngineOperation.Uninstall) throw new ArgumentException("Theme deletion is valid only during uninstall.");
    if (deep && operation is not (EngineOperation.Preflight or EngineOperation.Status)) throw new ArgumentException("Deep inspection is valid only for preflight and status.");
    if ((restartAuthorized || forceAuthorized) && operation is EngineOperation.Preflight or EngineOperation.Status or EngineOperation.Pause or EngineOperation.Verify)
      throw new ArgumentException("Authorization is invalid for this operation.");

    var arguments = new List<string> { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", adapterPath, "-Operation", operation.ToArgument() };
    if (restartAuthorized) arguments.Add("-RestartAuthorized");
    if (forceAuthorized) arguments.Add("-ForceAuthorized");
    if (deleteUserThemes) arguments.Add("-DeleteUserThemes");
    if (deep) arguments.Add("-Deep");
    return arguments;
  }
}

internal sealed class EngineProcessRunner : IEngineProcessRunner
{
  private const int OutputLimit = 1024 * 1024;
  private static readonly TimeSpan ReapTimeout = TimeSpan.FromSeconds(3);

  public async Task<EngineProcessResult> RunAsync(string fileName, IReadOnlyList<string> arguments, IProgress<EngineProgress>? progress, CancellationToken cancellationToken)
  {
    var startInfo = new ProcessStartInfo
    {
      FileName = fileName,
      UseShellExecute = false,
      CreateNoWindow = true,
      RedirectStandardOutput = true,
      RedirectStandardError = true,
      StandardOutputEncoding = new UTF8Encoding(false, true),
      StandardErrorEncoding = new UTF8Encoding(false, true)
    };
    foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);

    using var process = new Process { StartInfo = startInfo };
    if (!process.Start()) throw new InvalidOperationException("The engine process could not start.");
    var stdoutTask = ReadStandardOutputAsync(process.StandardOutput.BaseStream);
    var stderrTask = ReadProgressAsync(process.StandardError.BaseStream, progress);
    try { await process.WaitForExitAsync(cancellationToken); }
    catch (OperationCanceledException cancellation)
    {
      try { process.Kill(entireProcessTree: true); } catch { }
      try { await ObserveWithinAsync(process.WaitForExitAsync(CancellationToken.None)); } catch { }
      try { await ObserveWithinAsync(Task.WhenAll(stdoutTask, stderrTask)); } catch { }
      ExceptionDispatchInfo.Capture(cancellation).Throw();
      throw new UnreachableException();
    }
    var outputs = await Task.WhenAll(stdoutTask, stderrTask);
    return new EngineProcessResult(process.ExitCode, outputs[0], outputs[1]);
  }

  private static async Task<string> ReadStandardOutputAsync(Stream stream)
  {
    using var result = new MemoryStream();
    var buffer = new byte[4096];
    var exceeded = false;
    int read;
    while ((read = await stream.ReadAsync(buffer)) > 0)
    {
      if (result.Length + read <= OutputLimit) result.Write(buffer, 0, read);
      else exceeded = true;
    }
    if (exceeded) throw new InvalidDataException("The engine output exceeded its limit.");
    var bytes = result.ToArray();
    if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF)
      throw new InvalidDataException("The engine response contains a BOM.");
    return new UTF8Encoding(false, true).GetString(bytes);
  }

  private static async Task<string> ReadProgressAsync(Stream stream, IProgress<EngineProgress>? progress)
  {
    using var result = new MemoryStream();
    var line = new StringBuilder();
    var buffer = new byte[4096];
    var exceeded = false;
    Exception? protocolError = null;
    var total = 0;
    int read;
    while ((read = await stream.ReadAsync(buffer)) > 0)
    {
      total += read;
      if (total > OutputLimit) { exceeded = true; continue; }
      result.Write(buffer, 0, read);
      for (var index = 0; index < read; index++)
      {
        var value = buffer[index];
        if (value > 0x7F) { protocolError ??= new InvalidDataException("The engine progress output is not ASCII."); continue; }
        if (value == (byte)'\n')
        {
          var progressLine = line.ToString().TrimEnd('\r');
          line.Clear();
          if (progressLine.Length == 0) protocolError ??= new InvalidDataException("The engine progress output contains an empty line.");
          else if (protocolError is null)
          {
            try { EngineProtocol.ParseProgress(progressLine, progress); }
            catch (InvalidDataException exception) { protocolError = exception; }
          }
        }
        else line.Append((char)value);
      }
    }
    if (exceeded) throw new InvalidDataException("The engine output exceeded its limit.");
    if (line.Length > 0 && protocolError is null)
    {
      var progressLine = line.ToString().TrimEnd('\r');
      if (progressLine.Length == 0) protocolError = new InvalidDataException("The engine progress output contains an empty line.");
      else EngineProtocol.ParseProgress(progressLine, progress);
    }
    if (protocolError is not null) throw protocolError;
    return Encoding.ASCII.GetString(result.ToArray());
  }

  private static async Task ObserveWithinAsync(Task task)
  {
    try { await task.WaitAsync(ReapTimeout); }
    catch { _ = task.ContinueWith(completed => _ = completed.Exception, TaskContinuationOptions.OnlyOnFaulted); }
  }
}
