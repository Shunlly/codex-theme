using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace CodexDreamSkinStudio;

internal sealed record SingleInstanceRequest(string Command, string ExecutablePath);
internal sealed record SingleInstanceResponse(int ExitCode, int OwnerProcessId, bool ReleaseOwner);

internal sealed class SingleInstanceCoordinator : IDisposable
{
  private const int MessageLimit = 4096;
  private static readonly UTF8Encoding Utf8 = new(false, true);
  internal static TimeSpan RequestReadTimeout { get; } = TimeSpan.FromSeconds(2);
  private readonly Mutex _mutex;
  private readonly string _pipeName;
  private CancellationTokenSource? _serverCancellation;
  private Task? _serverTask;
  private bool _ownsInstance;
  private bool _disposed;

  internal SingleInstanceCoordinator(string userScope)
  {
    _pipeName = GetPipeName(userScope);
    _mutex = new Mutex(false, $"Local\\{_pipeName}");
  }

  internal static string GetPipeName(string userScope)
  {
    var digest = Convert.ToHexString(SHA256.HashData(Utf8.GetBytes(userScope))).ToLowerInvariant()[..32];
    return $"CodexDreamSkinStudio.{digest}";
  }

  internal bool TryAcquireOwnership()
  {
    if (_ownsInstance) return true;
    try { _ownsInstance = _mutex.WaitOne(0); }
    catch (AbandonedMutexException) { _ownsInstance = true; }
    return _ownsInstance;
  }

  internal void StartServer(
    Func<SingleInstanceRequest, CancellationToken, Task<SingleInstanceResponse>> handler,
    Action<SingleInstanceResponse, bool>? responseCompleted = null)
  {
    if (!_ownsInstance) throw new InvalidOperationException("Only the owning instance can start the control pipe.");
    if (_serverTask is not null) throw new InvalidOperationException("The control pipe is already running.");
    _serverCancellation = new CancellationTokenSource();
    _serverTask = Task.Run(() => ServeAsync(handler, responseCompleted, _serverCancellation.Token));
  }

  internal async Task<SingleInstanceResponse> ForwardAsync(
    string command,
    string executablePath,
    TimeSpan connectionTimeout,
    TimeSpan? responseTimeout)
  {
    if (command is not ("activate" or "prepare-uninstall")) throw new ArgumentException("The instance command is invalid.", nameof(command));
    if (String.IsNullOrWhiteSpace(executablePath)) throw new ArgumentException("The executable path is required.", nameof(executablePath));
    if (connectionTimeout <= TimeSpan.Zero) throw new ArgumentOutOfRangeException(nameof(connectionTimeout));
    if (responseTimeout is { } boundedResponse && boundedResponse <= TimeSpan.Zero) {
      throw new ArgumentOutOfRangeException(nameof(responseTimeout));
    }

    using var pipe = new NamedPipeClientStream(
      ".", _pipeName, PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
    try
    {
      using (var connectionCancellation = new CancellationTokenSource(connectionTimeout))
      {
        await pipe.ConnectAsync(connectionCancellation.Token);
      }
      using var writer = new StreamWriter(pipe, Utf8, 1024, leaveOpen: true);
      using var reader = new StreamReader(pipe, Utf8, detectEncodingFromByteOrderMarks: false, 1024, leaveOpen: true);
      using (var requestCancellation = new CancellationTokenSource(connectionTimeout))
      {
        await writer.WriteLineAsync(JsonSerializer.Serialize(new SingleInstanceRequest(command, executablePath)));
        await writer.FlushAsync(requestCancellation.Token);
      }
      string? line;
      if (responseTimeout is { } responseDeadline)
      {
        using var responseCancellation = new CancellationTokenSource(responseDeadline);
        line = await reader.ReadLineAsync(responseCancellation.Token);
      }
      else
      {
        line = await reader.ReadLineAsync(CancellationToken.None);
      }
      if (line is null || line.Length > MessageLimit) throw new InvalidDataException("The owner response is invalid.");
      var response = JsonSerializer.Deserialize<SingleInstanceResponse>(line) ??
        throw new InvalidDataException("The owner response is invalid.");
      if (response.OwnerProcessId <= 0) throw new InvalidDataException("The owner response has no process identity.");
      if (response.ReleaseOwner) await WaitForOwnerExitAsync(response.OwnerProcessId, connectionTimeout);
      return response;
    }
    catch (OperationCanceledException exception)
    {
      throw new TimeoutException("The owning Studio instance did not respond in time.", exception);
    }
  }

  private async Task ServeAsync(
    Func<SingleInstanceRequest, CancellationToken, Task<SingleInstanceResponse>> handler,
    Action<SingleInstanceResponse, bool>? responseCompleted,
    CancellationToken cancellationToken)
  {
    while (!cancellationToken.IsCancellationRequested)
    {
      using var pipe = new NamedPipeServerStream(
        _pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte,
        PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
      try { await pipe.WaitForConnectionAsync(cancellationToken); }
      catch (OperationCanceledException) { return; }

      var response = new SingleInstanceResponse(1, Environment.ProcessId, false);
      var requestParsed = false;
      var handlerCompleted = false;
      var delivered = false;
      CancellationTokenSource? requestCancellation = null;
      Task? disconnectMonitor = null;
      try
      {
        using var reader = new StreamReader(pipe, Utf8, detectEncodingFromByteOrderMarks: false, 1024, leaveOpen: true);
        using var requestReadCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        requestReadCancellation.CancelAfter(RequestReadTimeout);
        var line = await reader.ReadLineAsync(requestReadCancellation.Token);
        if (line is null || line.Length > MessageLimit) throw new InvalidDataException("The instance request is invalid.");
        var request = JsonSerializer.Deserialize<SingleInstanceRequest>(line) ??
          throw new InvalidDataException("The instance request is invalid.");
        if (request.Command is not ("activate" or "prepare-uninstall") ||
          String.IsNullOrWhiteSpace(request.ExecutablePath)) {
          throw new InvalidDataException("The instance request is invalid.");
        }
        requestParsed = true;
        requestCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        disconnectMonitor = MonitorClientDisconnectAsync(pipe, requestCancellation);
        response = await handler(request, requestCancellation.Token);
        handlerCompleted = true;
        if (requestCancellation.IsCancellationRequested) throw new OperationCanceledException(requestCancellation.Token);
        using var writer = new StreamWriter(pipe, Utf8, 1024, leaveOpen: true);
        await writer.WriteLineAsync(JsonSerializer.Serialize(response));
        await writer.FlushAsync(cancellationToken);
        delivered = true;
      }
      catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { return; }
      catch
      {
        if (!handlerCompleted) response = new SingleInstanceResponse(1, Environment.ProcessId, false);
        // A client that never completed a request may keep the pipe open while
        // it waits for a response. Close that instance without writing so it
        // cannot starve the next legitimate Studio invocation.
        if (!requestParsed) continue;
        try
        {
          using var writer = new StreamWriter(pipe, Utf8, 1024, leaveOpen: true);
          await writer.WriteLineAsync(JsonSerializer.Serialize(response));
          await writer.FlushAsync(cancellationToken);
          delivered = true;
        }
        catch { }
      }
      finally
      {
        requestCancellation?.Cancel();
        if (disconnectMonitor is not null) {
          try { await disconnectMonitor; } catch { }
        }
        requestCancellation?.Dispose();
      }
      responseCompleted?.Invoke(response, delivered);
    }
  }

  private static async Task MonitorClientDisconnectAsync(
    PipeStream pipe,
    CancellationTokenSource requestCancellation)
  {
    var probe = new byte[1];
    try
    {
      await pipe.ReadAsync(probe, requestCancellation.Token);
      requestCancellation.Cancel();
    }
    catch (OperationCanceledException) { }
    catch
    {
      requestCancellation.Cancel();
    }
  }

  private static async Task WaitForOwnerExitAsync(int ownerProcessId, TimeSpan timeout)
  {
    Process owner;
    try { owner = Process.GetProcessById(ownerProcessId); }
    catch (ArgumentException) { return; }
    using (owner)
    using (var cancellation = new CancellationTokenSource(timeout))
    {
      try { await owner.WaitForExitAsync(cancellation.Token); }
      catch (OperationCanceledException exception)
      {
        throw new TimeoutException("The owning Studio instance did not release its executable in time.", exception);
      }
    }
  }

  public void Dispose()
  {
    if (_disposed) return;
    _disposed = true;
    _serverCancellation?.Cancel();
    try { _serverTask?.Wait(1000); } catch { }
    _serverCancellation?.Dispose();
    if (_ownsInstance)
    {
      try { _mutex.ReleaseMutex(); } catch (ApplicationException) { }
    }
    _mutex.Dispose();
  }
}
