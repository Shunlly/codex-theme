using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using CodexDreamSkinStudio;

static void Assert(bool condition, string message)
{
  if (!condition) throw new InvalidOperationException(message);
}

static void Throws<T>(Action action, string message) where T : Exception
{
  try { action(); }
  catch (T) { return; }
  throw new InvalidOperationException(message);
}

static async Task ThrowsAsync<T>(Func<Task> action, string message) where T : Exception
{
  try { await action(); }
  catch (T) { return; }
  throw new InvalidOperationException(message);
}

static async Task<Process> StartInstanceOwnerAsync(string scope, string mode, string readyPath, string tracePath)
{
  var process = Process.Start(new ProcessStartInfo
  {
    FileName = Environment.ProcessPath!,
    UseShellExecute = false,
    ArgumentList = { "--single-instance-owner", scope, mode, readyPath, tracePath }
  })!;
  var deadline = DateTime.UtcNow.AddSeconds(5);
  while (!File.Exists(readyPath) && DateTime.UtcNow < deadline)
  {
    if (process.HasExited) throw new InvalidOperationException("Controlled single-instance owner exited before readiness.");
    await Task.Delay(20);
  }
  if (!File.Exists(readyPath)) throw new InvalidOperationException("Controlled single-instance owner did not become ready.");
  return process;
}

static void StopControlledProcess(Process process)
{
  if (!process.HasExited)
  {
    try { process.Kill(entireProcessTree: true); } catch { }
    process.WaitForExit(5000);
  }
  process.Dispose();
}

static string Mutate(string json, Action<JsonObject> mutation)
{
  var root = JsonNode.Parse(json)!.AsObject();
  mutation(root);
  return root.ToJsonString();
}

static async Task RunChildAsync(string[] arguments)
{
  switch (arguments[0])
  {
    case "--engine-child-progress":
      Console.Error.Write("DREAM_SKIN_PRO");
      Console.Error.Flush();
      await Task.Delay(50);
      Console.Error.WriteLine("GRESS=checking");
      Console.Error.WriteLine("DREAM_SKIN_PROGRESS=applying");
      Console.Write("child-ok");
      return;
    case "--engine-child-oversized":
      Console.Write(new string('x', 1024 * 1024 + 1));
      return;
    case "--engine-child-tree":
      var grandchild = Process.Start(new ProcessStartInfo
      {
        FileName = Environment.ProcessPath!,
        UseShellExecute = false,
        ArgumentList = { "--engine-grandchild", arguments[1] }
      })!;
      await File.WriteAllTextAsync(arguments[1], grandchild.Id.ToString());
      await Task.Delay(Timeout.InfiniteTimeSpan);
      return;
    case "--engine-grandchild":
      await Task.Delay(Timeout.InfiniteTimeSpan);
      return;
    case "--single-instance-owner":
      var scope = arguments[1];
      var mode = arguments[2];
      var readyPath = arguments[3];
      var tracePath = arguments[4];
      using (var coordinator = new SingleInstanceCoordinator(scope))
      {
        if (!coordinator.TryAcquireOwnership()) throw new InvalidOperationException("Controlled owner could not acquire ownership.");
        if (mode != "no-server")
        {
          var reservation = new HandoffReservation();
          coordinator.StartServer(async (request, cancellationToken) =>
          {
            File.AppendAllText(tracePath, request.Command + Environment.NewLine);
            if (mode == "delayed-response") await Task.Delay(TimeSpan.FromSeconds(16), cancellationToken);
            if (mode == "disconnect-before-mutation")
            {
              try { await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken); }
              catch (OperationCanceledException)
              {
                File.AppendAllText(tracePath, "cancelled-before-mutation" + Environment.NewLine);
                return new SingleInstanceResponse(1, Environment.ProcessId, false);
              }
              File.AppendAllText(tracePath, "mutation-entered" + Environment.NewLine);
            }
            if (mode == "disconnect-active-engine")
            {
              var runner = new BlockingRunner();
              var client = new EngineClient(runner, @"C:\Windows", TimeSpan.FromMinutes(1));
              var active = client.RunAsync(EngineOperation.Status, deep: true, cancellationToken: cancellationToken);
              await runner.Started.Task;
              File.AppendAllText(tracePath, "active-engine-started" + Environment.NewLine);
              try { await active; }
              catch (OperationCanceledException)
              {
                File.AppendAllText(tracePath, "active-engine-cancelled" + Environment.NewLine);
                return new SingleInstanceResponse(1, Environment.ProcessId, false);
              }
              throw new InvalidOperationException("Disconnected active engine was not cancelled.");
            }
            if (mode == "delivery-failure")
            {
              if (!reservation.TryBegin(busy: false, confirming: false)) {
                return new SingleInstanceResponse(1, Environment.ProcessId, false);
              }
              File.AppendAllText(tracePath, "handler-ready" + Environment.NewLine);
              while (File.Exists(tracePath + ".gate")) await Task.Delay(20);
              return new SingleInstanceResponse(0, Environment.ProcessId, true);
            }
            var releaseOwner = request.Command == "prepare-uninstall" && mode == "success" ||
              request.Command == "activate" && mode == "version-handoff" &&
              !String.Equals(request.ExecutablePath, Environment.ProcessPath, StringComparison.OrdinalIgnoreCase);
            var exitCode = request.Command == "prepare-uninstall" ? mode switch
            {
              "failure" => 7,
              "busy" => 9,
              "delayed-response" => 7,
              _ => 0
            } : 0;
            if (releaseOwner && !reservation.TryBegin(busy: false, confirming: false)) {
              return new SingleInstanceResponse(1, Environment.ProcessId, false);
            }
            return new SingleInstanceResponse(exitCode, Environment.ProcessId, releaseOwner);
          }, (response, delivered) =>
          {
            if (!response.ReleaseOwner) return;
            if (delivered) Environment.Exit(0);
            reservation.Cancel();
            File.AppendAllText(tracePath, "reservation-cancelled" + Environment.NewLine);
          });
        }
        await File.WriteAllTextAsync(readyPath, Environment.ProcessId.ToString());
        await Task.Delay(Timeout.InfiniteTimeSpan);
      }
      return;
  }
  throw new InvalidOperationException("Unknown controlled child mode.");
}

if (args.Length > 0)
{
  await RunChildAsync(args);
  return;
}

var fixtures = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(AppContext.BaseDirectory, "fixtures-v1.json")));
foreach (var fixture in fixtures.RootElement.EnumerateArray())
{
  var response = fixture.GetProperty("response").GetRawText();
  var envelope = EngineProtocol.Parse(response, Enum.Parse<EngineOperation>(fixture.GetProperty("response").GetProperty("operation").GetString()!, true));
  Assert(envelope.SchemaVersion == 1, "Fixture schema did not parse.");
}
var utf8 = EngineProtocol.Parse(fixtures.RootElement[2].GetProperty("response").GetRawText(), EngineOperation.Install);
Assert(utf8.State.ThemeName == "午夜极光", "UTF-8 theme name was not preserved.");

var valid = fixtures.RootElement[3].GetProperty("response").GetRawText();
Throws<JsonException>(() => EngineProtocol.Parse("not json", EngineOperation.Apply), "Invalid JSON was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse("\uFEFF" + valid, EngineOperation.Apply), "A BOM was accepted.");
Throws<JsonException>(() => EngineProtocol.Parse(valid + "{}", EngineOperation.Apply), "Extra stdout was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(valid.Replace("\"schemaVersion\": 1", "\"schemaVersion\": 2"), EngineOperation.Apply), "Unknown schema was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(valid.Replace("\"verified\": true", "\"verified\": false"), EngineOperation.Apply), "Unverified successful apply was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(valid.Replace("\"operation\": \"apply\"", "\"operation\": \"status\""), EngineOperation.Apply), "Response/request operation mismatch was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(valid.Replace("\"session\": \"active\"", "\"session\": \"unknown\""), EngineOperation.Apply), "Unknown state enum was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(fixtures.RootElement[6].GetProperty("response").GetRawText().Replace("RESTART_REQUIRED", "UNKNOWN_ERROR"), EngineOperation.Apply), "Unknown error code was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(valid.Replace("\"pause\", \"resume\"", "\"pause\", \"pause\""), EngineOperation.Apply), "Duplicate actions were accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(valid.Replace("\"error\": null", "\"error\": {\"code\":\"X\",\"message\":\"x\",\"recoveryActions\":[\"cancel\"]}"), EngineOperation.Apply), "Invalid success shape was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(valid.Replace("\"themeName\": \"午夜极光\",", ""), EngineOperation.Apply), "Missing state field was accepted.");

var restartRequired = fixtures.RootElement[6].GetProperty("response").GetRawText();
var restored = fixtures.RootElement[9].GetProperty("response").GetRawText();
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(valid, root => root["state"]!["install"] = "not-installed"), EngineOperation.Apply), "An active session without a ready install was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(valid, root => root["state"]!["codex"] = "stopped"), EngineOperation.Apply), "An active session without running Codex was accepted.");
Assert(EngineProtocol.Parse(Mutate(restored, root => root["state"]!["verified"] = true), EngineOperation.Restore).State.Verified == true, "Verified true outside an active session was rejected.");
Assert(EngineProtocol.Parse(Mutate(restartRequired, root => { root["state"]!["operation"] = "busy"; root["error"]!["code"] = "OPERATION_BUSY"; }), EngineOperation.Apply).State.AvailableActions.Length > 0, "Busy state actions were rejected by an unfrozen rule.");
Assert(EngineProtocol.Parse(Mutate(restartRequired, root => root["error"]!["recoveryActions"] = new JsonArray("cancel", "cancel")), EngineOperation.Apply).Error?.RecoveryActions.Length == 2, "Duplicate allowed recovery actions were rejected.");
const string retainedThemeLifecycleError = "{\"schemaVersion\":1,\"ok\":false,\"operation\":\"install\",\"state\":{\"install\":\"not-installed\",\"codex\":\"not-installed\",\"session\":\"official\",\"operation\":\"idle\",\"themeName\":\"午夜极光\",\"requiresRestart\":false,\"availableActions\":[\"install\"],\"verified\":null},\"error\":{\"code\":\"CODEX_NOT_INSTALLED\",\"message\":\"Codex is not installed.\",\"recoveryActions\":[\"cancel\"]}}";
Assert(EngineProtocol.Parse(retainedThemeLifecycleError, EngineOperation.Install).State.ThemeName == "午夜极光", "A valid retained-theme lifecycle error was rejected.");

Assert(EngineOperation.Uninstall.ToArgument() == "uninstall", "Operation mapping was not lowercase.");
var adapterPath = Path.Combine(AppContext.BaseDirectory, "engine", "scripts", "studio-adapter.ps1");
var argv = EngineClient.BuildArguments(EngineOperation.Uninstall, adapterPath, true, true, true, false);
Assert(argv.SequenceEqual(new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", adapterPath, "-Operation", "uninstall", "-RestartAuthorized", "-ForceAuthorized", "-DeleteUserThemes" }), "Authorization argv was not exact.");
var deepArgv = EngineClient.BuildArguments(EngineOperation.Preflight, adapterPath, false, false, false, true);
Assert(deepArgv[^1] == "-Deep", "Deep preflight was omitted.");
Throws<ArgumentException>(() => EngineClient.BuildArguments(EngineOperation.Apply, adapterPath, false, false, true, false), "Theme deletion outside uninstall was accepted.");
Throws<ArgumentException>(() => EngineClient.BuildArguments(EngineOperation.Apply, adapterPath, false, true, false, false), "Force without restart was accepted.");
Throws<ArgumentException>(() => EngineClient.BuildArguments(EngineOperation.Apply, adapterPath, false, false, false, true), "Deep lifecycle operation was accepted.");
Throws<ArgumentException>(() => EngineClient.BuildArguments(EngineOperation.Pause, adapterPath, true, false, false, false), "Pause authorization was accepted.");
Assert(!MainWindow.AllowsTermination(busy: true), "Busy window termination was allowed.");
Assert(MainWindow.AllowsTermination(busy: false), "Idle window termination was vetoed.");
Assert(MainWindow.AllowsRefresh(busy: false, confirming: false), "Idle status refresh was unavailable.");
Assert(!MainWindow.AllowsRefresh(busy: true, confirming: false), "Busy status refresh was allowed.");
Assert(!MainWindow.AllowsRefresh(busy: false, confirming: true), "Confirmation allowed a concurrent status refresh.");
var handoffReservation = new HandoffReservation();
Assert(handoffReservation.TryBegin(busy: false, confirming: false), "Idle handoff could not reserve the owner.");
Assert(!MainWindow.AllowsDispatch(busy: false, confirming: false, handoffReservation.IsActive),
  "An operation entered after the owner promised release.");
Assert(!MainWindow.AllowsTermination(busy: false, handoffReserved: true),
  "Owner exit bypassed a pending release response.");
handoffReservation.Cancel();
Assert(MainWindow.AllowsDispatch(busy: false, confirming: false, handoffReservation.IsActive),
  "Failed response delivery did not release the handoff reservation.");

var instanceRoot = Path.Combine(Path.GetTempPath(), $"dream-skin-instance-{Guid.NewGuid():N}");
Directory.CreateDirectory(instanceRoot);
try
{
  var successScope = $"success-{Guid.NewGuid():N}";
  var successReady = Path.Combine(instanceRoot, "success.ready");
  var successTrace = Path.Combine(instanceRoot, "success.trace");
  var successOwner = await StartInstanceOwnerAsync(successScope, "success", successReady, successTrace);
  try
  {
    using var client = new SingleInstanceCoordinator(successScope);
    Assert(!client.TryAcquireOwnership(), "Second instance acquired ownership while the owner was alive.");
    var activated = await client.ForwardAsync("activate", Environment.ProcessPath!,
      TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));
    Assert(activated.ExitCode == 0 && activated.OwnerProcessId == successOwner.Id && !activated.ReleaseOwner,
      "Ordinary activation did not return the live owner identity.");
    Assert(!successOwner.HasExited, "Ordinary activation terminated the owner.");
    var prepared = await client.ForwardAsync("prepare-uninstall", Environment.ProcessPath!,
      TimeSpan.FromSeconds(5), responseTimeout: null);
    Assert(prepared.ExitCode == 0 && prepared.OwnerProcessId == successOwner.Id && prepared.ReleaseOwner,
      "Successful prepare-uninstall did not propagate success and release intent.");
    Assert(successOwner.HasExited, "Successful prepare-uninstall returned before the owner executable was released.");
    Assert((await File.ReadAllTextAsync(successTrace)).Contains("activate") &&
      (await File.ReadAllTextAsync(successTrace)).Contains("prepare-uninstall"),
      "Owner did not receive both control commands.");
  }
  finally { StopControlledProcess(successOwner); }

  foreach (var (mode, expectedExit) in new[] { ("failure", 7), ("busy", 9) })
  {
    var scope = $"{mode}-{Guid.NewGuid():N}";
    var ready = Path.Combine(instanceRoot, $"{mode}.ready");
    var trace = Path.Combine(instanceRoot, $"{mode}.trace");
    var owner = await StartInstanceOwnerAsync(scope, mode, ready, trace);
    try
    {
      using var client = new SingleInstanceCoordinator(scope);
      var response = await client.ForwardAsync("prepare-uninstall", Environment.ProcessPath!,
        TimeSpan.FromSeconds(5), responseTimeout: null);
      Assert(response.ExitCode == expectedExit && !response.ReleaseOwner,
        $"{mode} prepare-uninstall did not preserve its exact failure code.");
      Assert(!owner.HasExited, $"{mode} prepare-uninstall terminated the owner.");
    }
    finally { StopControlledProcess(owner); }
  }

  var timeoutScope = $"timeout-{Guid.NewGuid():N}";
  var timeoutOwner = await StartInstanceOwnerAsync(timeoutScope, "no-server",
    Path.Combine(instanceRoot, "timeout.ready"), Path.Combine(instanceRoot, "timeout.trace"));
  try
  {
    using var client = new SingleInstanceCoordinator(timeoutScope);
    await ThrowsAsync<TimeoutException>(async () =>
      await client.ForwardAsync("activate", Environment.ProcessPath!,
        TimeSpan.FromMilliseconds(250), TimeSpan.FromMilliseconds(250)),
      "A missing owner pipe did not fail within the response timeout.");
  }
  finally { StopControlledProcess(timeoutOwner); }

  var handoffScope = $"handoff-{Guid.NewGuid():N}";
  var handoffOwner = await StartInstanceOwnerAsync(handoffScope, "version-handoff",
    Path.Combine(instanceRoot, "handoff.ready"), Path.Combine(instanceRoot, "handoff.trace"));
  try
  {
    using var client = new SingleInstanceCoordinator(handoffScope);
    var response = await client.ForwardAsync("activate", @"C:\new-version\CodexDreamSkinStudio.exe",
      TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));
    Assert(response.ExitCode == 0 && response.ReleaseOwner && handoffOwner.HasExited,
      "Version handoff returned before the prior executable was released.");
  }
  finally { StopControlledProcess(handoffOwner); }

  var delayedScope = $"delayed-{Guid.NewGuid():N}";
  var delayedOwner = await StartInstanceOwnerAsync(delayedScope, "delayed-response",
    Path.Combine(instanceRoot, "delayed.ready"), Path.Combine(instanceRoot, "delayed.trace"));
  try
  {
    using var client = new SingleInstanceCoordinator(delayedScope);
    var elapsed = Stopwatch.StartNew();
    var response = await client.ForwardAsync("prepare-uninstall", Environment.ProcessPath!,
      TimeSpan.FromSeconds(5), responseTimeout: null);
    Assert(response.ExitCode == 7 && elapsed.Elapsed >= TimeSpan.FromSeconds(15),
      "Interactive prepare-uninstall retained activation's short response deadline.");
  }
  finally { StopControlledProcess(delayedOwner); }

  var silentScope = $"silent-{Guid.NewGuid():N}";
  var silentOwner = await StartInstanceOwnerAsync(silentScope, "failure",
    Path.Combine(instanceRoot, "silent.ready"), Path.Combine(instanceRoot, "silent.trace"));
  try
  {
    using var silent = new NamedPipeClientStream(".", SingleInstanceCoordinator.GetPipeName(silentScope),
      PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
    await silent.ConnectAsync(5000);
    await Task.Delay(SingleInstanceCoordinator.RequestReadTimeout + TimeSpan.FromMilliseconds(500));
    using var client = new SingleInstanceCoordinator(silentScope);
    var response = await client.ForwardAsync("activate", Environment.ProcessPath!,
      TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));
    Assert(response.ExitCode == 0, "A connected silent client monopolized the owner pipe.");
  }
  finally { StopControlledProcess(silentOwner); }

  var disconnectScope = $"disconnect-{Guid.NewGuid():N}";
  var disconnectTrace = Path.Combine(instanceRoot, "disconnect.trace");
  var disconnectOwner = await StartInstanceOwnerAsync(disconnectScope, "disconnect-before-mutation",
    Path.Combine(instanceRoot, "disconnect.ready"), disconnectTrace);
  try
  {
    using var client = new SingleInstanceCoordinator(disconnectScope);
    await ThrowsAsync<TimeoutException>(async () => await client.ForwardAsync("prepare-uninstall",
      Environment.ProcessPath!, TimeSpan.FromSeconds(5), TimeSpan.FromMilliseconds(250)),
      "A disconnected prepare-uninstall client did not time out.");
    var deadline = DateTime.UtcNow.AddSeconds(5);
    while ((!File.Exists(disconnectTrace) || !File.ReadAllText(disconnectTrace).Contains("cancelled-before-mutation")) &&
      DateTime.UtcNow < deadline) await Task.Delay(20);
    var trace = File.ReadAllText(disconnectTrace);
    Assert(trace.Contains("cancelled-before-mutation") && !trace.Contains("mutation-entered"),
      "Owner mutation started after the prepare-uninstall client disconnected.");
  }
  finally { StopControlledProcess(disconnectOwner); }

  var activeDisconnectScope = $"active-disconnect-{Guid.NewGuid():N}";
  var activeDisconnectTrace = Path.Combine(instanceRoot, "active-disconnect.trace");
  var activeDisconnectOwner = await StartInstanceOwnerAsync(activeDisconnectScope, "disconnect-active-engine",
    Path.Combine(instanceRoot, "active-disconnect.ready"), activeDisconnectTrace);
  try
  {
    using (var client = new NamedPipeClientStream(".", SingleInstanceCoordinator.GetPipeName(activeDisconnectScope),
      PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly))
    {
      await client.ConnectAsync(5000);
      using var writer = new StreamWriter(client, new UTF8Encoding(false), 1024, leaveOpen: true);
      await writer.WriteLineAsync(JsonSerializer.Serialize(new SingleInstanceRequest("prepare-uninstall", Environment.ProcessPath!)));
      await writer.FlushAsync();
      var startedDeadline = DateTime.UtcNow.AddSeconds(5);
      while ((!File.Exists(activeDisconnectTrace) || !File.ReadAllText(activeDisconnectTrace).Contains("active-engine-started")) &&
        DateTime.UtcNow < startedDeadline) await Task.Delay(20);
      Assert(File.Exists(activeDisconnectTrace) && File.ReadAllText(activeDisconnectTrace).Contains("active-engine-started"),
        "Pipe-disconnect fixture did not start its engine call.");
    }
    var cancelledDeadline = DateTime.UtcNow.AddSeconds(5);
    while (!File.ReadAllText(activeDisconnectTrace).Contains("active-engine-cancelled") &&
      DateTime.UtcNow < cancelledDeadline) await Task.Delay(20);
    Assert(File.ReadAllText(activeDisconnectTrace).Contains("active-engine-cancelled"),
      "Active engine call ignored named-pipe disconnect cancellation.");
    Assert(!activeDisconnectOwner.HasExited, "Cancelled active engine call released the resident owner.");
  }
  finally { StopControlledProcess(activeDisconnectOwner); }

  var deliveryFailureScope = $"delivery-failure-{Guid.NewGuid():N}";
  var deliveryFailureTrace = Path.Combine(instanceRoot, "delivery-failure.trace");
  var deliveryFailureGate = deliveryFailureTrace + ".gate";
  File.WriteAllText(deliveryFailureGate, "wait");
  var deliveryFailureOwner = await StartInstanceOwnerAsync(deliveryFailureScope, "delivery-failure",
    Path.Combine(instanceRoot, "delivery-failure.ready"), deliveryFailureTrace);
  try
  {
    using (var client = new NamedPipeClientStream(".", SingleInstanceCoordinator.GetPipeName(deliveryFailureScope),
      PipeDirection.InOut, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly))
    {
      await client.ConnectAsync(5000);
      using var writer = new StreamWriter(client, new UTF8Encoding(false), 1024, leaveOpen: true);
      await writer.WriteLineAsync(JsonSerializer.Serialize(new SingleInstanceRequest("prepare-uninstall", Environment.ProcessPath!)));
      await writer.FlushAsync();
      var deadline = DateTime.UtcNow.AddSeconds(5);
      while ((!File.Exists(deliveryFailureTrace) || !File.ReadAllText(deliveryFailureTrace).Contains("handler-ready")) &&
        DateTime.UtcNow < deadline) await Task.Delay(20);
      Assert(File.Exists(deliveryFailureTrace) && File.ReadAllText(deliveryFailureTrace).Contains("handler-ready"),
        "Delivery-failure handler did not reserve the handoff before client disconnect.");
    }
    File.Delete(deliveryFailureGate);
    var cancelledDeadline = DateTime.UtcNow.AddSeconds(5);
    while ((!File.Exists(deliveryFailureTrace) || !File.ReadAllText(deliveryFailureTrace).Contains("reservation-cancelled")) &&
      DateTime.UtcNow < cancelledDeadline) await Task.Delay(20);
    Assert(File.ReadAllText(deliveryFailureTrace).Contains("reservation-cancelled"),
      "Failed response delivery did not cancel the reserved handoff.");
    Assert(!deliveryFailureOwner.HasExited, "Failed response delivery terminated the owner.");
  }
  finally
  {
    if (File.Exists(deliveryFailureGate)) File.Delete(deliveryFailureGate);
    StopControlledProcess(deliveryFailureOwner);
  }
}
finally { Directory.Delete(instanceRoot, recursive: true); }

var progress = new List<EngineProgress>();
EngineProtocol.ParseProgress("DREAM_SKIN_PROGRESS=checking\r\nDREAM_SKIN_PROGRESS=applying\r\n", new InlineProgress<EngineProgress>(progress.Add));
Assert(progress.SequenceEqual(new[] { EngineProgress.Checking, EngineProgress.Applying }), "Progress chunks were not parsed.");
Throws<InvalidDataException>(() => EngineProtocol.ParseProgress("raw error\n", null), "Raw stderr was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.ParseProgress("DREAM_SKIN_PROGRESS=mystery\n", null), "Unknown progress was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.ParseProgress("DREAM_SKIN_PROGRESS checking\n", null), "Legacy progress was accepted.");

var invalidRequest = Mutate(restartRequired, root => root["error"]!["code"] = "INVALID_REQUEST");
foreach (var accepted in new[] { new EngineProcessResult(0, valid, ""), new EngineProcessResult(1, restartRequired, ""), new EngineProcessResult(2, invalidRequest, "") })
  Assert((await new EngineClient(new FakeRunner(accepted), "C:\\Windows").RunAsync(EngineOperation.Apply, deep: false)).SchemaVersion == 1, $"Valid exit {accepted.ExitCode} was rejected.");
await ThrowsAsync<InvalidDataException>(async () => await new EngineClient(new FakeRunner(new EngineProcessResult(1, invalidRequest, "")), "C:\\Windows").RunAsync(EngineOperation.Apply, deep: false), "INVALID_REQUEST at exit 1 was accepted.");
await ThrowsAsync<InvalidDataException>(async () => await new EngineClient(new FakeRunner(new EngineProcessResult(2, restartRequired, "")), "C:\\Windows").RunAsync(EngineOperation.Apply, deep: false), "Domain error at exit 2 was accepted.");
Assert((await new EngineClient(new FakeRunner(new EngineProcessResult(1, retainedThemeLifecycleError, "")), "C:\\Windows").RunAsync(EngineOperation.Install, deep: false)).State.ThemeName == "午夜极光", "The retained-theme lifecycle error was not accepted at exit 1.");
var pathRunner = new FakeRunner(new EngineProcessResult(0, valid, ""));
await new EngineClient(pathRunner, "C:\\Windows").RunAsync(EngineOperation.Apply, deep: false);
Assert(pathRunner.FileName == "C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", "The fixed Windows PowerShell path was not used.");
Assert(pathRunner.Arguments![5] == adapterPath, "The fixed adapter path was not used.");
await ThrowsAsync<InvalidDataException>(async () => await new EngineClient(new FakeRunner(new EngineProcessResult(3, valid, "")), "C:\\Windows").RunAsync(EngineOperation.Apply, deep: false), "Process failure was accepted.");

var blocking = new BlockingRunner();
var busyClient = new EngineClient(blocking, "C:\\Windows");
var first = busyClient.RunAsync(EngineOperation.Status, deep: true);
await blocking.Started.Task;
await ThrowsAsync<InvalidOperationException>(async () => await busyClient.RunAsync(EngineOperation.Status, deep: true), "Busy reentry was accepted.");
blocking.Release.SetResult();
await first;
Assert(blocking.Calls == 1, "Busy reentry launched a process.");

using var cancellation = new CancellationTokenSource();
var cancelling = new BlockingRunner();
var cancellationClient = new EngineClient(cancelling, "C:\\Windows");
var cancelled = cancellationClient.RunAsync(EngineOperation.Status, deep: true, cancellationToken: cancellation.Token);
await cancelling.Started.Task;
cancellation.Cancel();
await ThrowsAsync<OperationCanceledException>(async () => await cancelled, "Cancellation did not propagate.");
Assert(cancelling.Cancelled, "Cancellation did not reach the process boundary.");

Throws<ArgumentOutOfRangeException>(() =>
  new EngineClient(new FakeRunner(new EngineProcessResult(0, valid, "")), "C:\\Windows", TimeSpan.Zero),
  "A non-positive production engine deadline was accepted.");
var deadlineRunner = new BlockingRunner();
var deadlineClient = new EngineClient(deadlineRunner, "C:\\Windows", TimeSpan.FromMilliseconds(100));
var deadlineExpired = deadlineClient.RunAsync(EngineOperation.Status, deep: true);
await deadlineRunner.Started.Task;
await ThrowsAsync<OperationCanceledException>(async () => await deadlineExpired.WaitAsync(TimeSpan.FromSeconds(5)),
  "Production engine invocation ignored its deadline.");
Assert(deadlineRunner.Cancelled, "Production deadline did not reach the process boundary.");

var realRunner = new EngineProcessRunner();
var realProgress = new List<EngineProgress>();
var realResult = await realRunner.RunAsync(Environment.ProcessPath!, ["--engine-child-progress"], new InlineProgress<EngineProgress>(realProgress.Add), CancellationToken.None);
Assert(realResult.ExitCode == 0 && realResult.StandardOutput == "child-ok", "The production runner did not capture controlled stdout.");
Assert(realProgress.SequenceEqual(new[] { EngineProgress.Checking, EngineProgress.Applying }), "The production runner did not parse chunked progress.");
await ThrowsAsync<InvalidDataException>(async () => await realRunner.RunAsync(Environment.ProcessPath!, ["--engine-child-oversized"], null, CancellationToken.None), "The production runner accepted oversized output.");

var marker = Path.Combine(Path.GetTempPath(), $"dream-skin-runner-{Guid.NewGuid():N}.pid");
try
{
  using var realCancellation = new CancellationTokenSource();
  var realCancelled = realRunner.RunAsync(Environment.ProcessPath!, ["--engine-child-tree", marker], null, realCancellation.Token);
  var markerDeadline = DateTime.UtcNow.AddSeconds(5);
  var grandchildId = 0;
  while (grandchildId == 0 && DateTime.UtcNow < markerDeadline)
  {
    if (File.Exists(marker)) int.TryParse(await File.ReadAllTextAsync(marker), out grandchildId);
    if (grandchildId == 0) await Task.Delay(20);
  }
  Assert(grandchildId > 0, "The controlled process tree did not start.");
  realCancellation.Cancel();
  var elapsed = Stopwatch.StartNew();
  await ThrowsAsync<OperationCanceledException>(async () => await realCancelled.WaitAsync(TimeSpan.FromSeconds(10)), "Runner cancellation did not preserve OperationCanceledException.");
  Assert(elapsed.Elapsed < TimeSpan.FromSeconds(10), "Runner cancellation did not reap within its bound.");
  await Task.Delay(250);
  Throws<ArgumentException>(() => Process.GetProcessById(grandchildId), "Runner cancellation left the controlled grandchild alive.");
}
finally { if (File.Exists(marker)) File.Delete(marker); }

Console.WriteLine("PASS: Dream Skin Studio engine client.");

sealed class FakeRunner(EngineProcessResult result) : IEngineProcessRunner
{
  public string? FileName { get; private set; }
  public IReadOnlyList<string>? Arguments { get; private set; }
  public Task<EngineProcessResult> RunAsync(string fileName, IReadOnlyList<string> arguments, IProgress<EngineProgress>? progress, CancellationToken cancellationToken)
  {
    FileName = fileName;
    Arguments = arguments;
    return Task.FromResult(result);
  }
}

sealed class BlockingRunner : IEngineProcessRunner
{
  public TaskCompletionSource Started { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
  public TaskCompletionSource Release { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
  public int Calls { get; private set; }
  public bool Cancelled { get; private set; }

  public async Task<EngineProcessResult> RunAsync(string fileName, IReadOnlyList<string> arguments, IProgress<EngineProgress>? progress, CancellationToken cancellationToken)
  {
    Calls++;
    Started.SetResult();
    try { await Release.Task.WaitAsync(cancellationToken); }
    catch (OperationCanceledException) { Cancelled = true; throw; }
    return new EngineProcessResult(0, "{\"schemaVersion\":1,\"ok\":true,\"operation\":\"status\",\"state\":{\"install\":\"ready\",\"codex\":\"stopped\",\"session\":\"official\",\"operation\":\"idle\",\"themeName\":null,\"requiresRestart\":false,\"availableActions\":[\"apply\",\"restore\",\"uninstall\"],\"verified\":null},\"error\":null}", "");
  }
}

sealed class InlineProgress<T>(Action<T> report) : IProgress<T>
{
  public void Report(T value) => report(value);
}
