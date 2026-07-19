using System.Diagnostics;
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
      Console.Error.WriteLine("GRESS checking");
      Console.Error.WriteLine("DREAM_SKIN_PROGRESS applying");
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

var installed = fixtures.RootElement[2].GetProperty("response").GetRawText();
var paused = fixtures.RootElement[4].GetProperty("response").GetRawText();
var restartRequired = fixtures.RootElement[6].GetProperty("response").GetRawText();
var restored = fixtures.RootElement[9].GetProperty("response").GetRawText();
var uninstalled = fixtures.RootElement[10].GetProperty("response").GetRawText();
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(installed, root => root["state"]!["requiresRestart"] = true), EngineOperation.Install), "Restart-required stopped state was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(installed, root => root["state"]!["availableActions"]!.AsArray().Add("install")), EngineOperation.Install), "Install action for a ready engine was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(uninstalled, root => root["state"]!["availableActions"] = new JsonArray("apply")), EngineOperation.Uninstall), "Ready-only action for a missing engine was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(restartRequired, root => { root["state"]!["operation"] = "busy"; root["state"]!["availableActions"] = new JsonArray(); }), EngineOperation.Apply), "Busy state without OPERATION_BUSY was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(restartRequired, root => root["error"]!["code"] = "OPERATION_BUSY"), EngineOperation.Apply), "OPERATION_BUSY with idle state was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(paused, root => { root["state"]!["install"] = "not-installed"; root["state"]!["themeName"] = null; root["state"]!["availableActions"] = new JsonArray("install"); }), EngineOperation.Pause), "Managed session without a ready install was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(installed, root => root["state"]!["availableActions"]!.AsArray().Add("pause")), EngineOperation.Install), "Pause outside an active session was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(valid, root => root["state"]!["availableActions"]!.AsArray().Add("apply")), EngineOperation.Apply), "Apply action for an active session was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(paused, root => root["state"]!["session"] = "official"), EngineOperation.Pause), "Successful pause without a paused session was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(restored, root => root["state"]!["session"] = "paused"), EngineOperation.Restore), "Successful restore without an official session was accepted.");

const string statusFailure = "{\"schemaVersion\":1,\"ok\":false,\"operation\":\"status\",\"state\":{\"install\":\"not-installed\",\"codex\":\"not-installed\",\"session\":\"stale\",\"operation\":\"idle\",\"themeName\":null,\"requiresRestart\":false,\"availableActions\":[],\"verified\":null},\"error\":{\"code\":\"INTERNAL_ERROR\",\"message\":\"Studio status could not be read safely.\",\"recoveryActions\":[\"retry\",\"diagnostics\",\"cancel\"]}}";
Assert(EngineProtocol.Parse(statusFailure, EngineOperation.Status).Error?.Code == "INTERNAL_ERROR", "The safe Task 7 status failure was rejected.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(statusFailure, root => root["state"]!["availableActions"] = new JsonArray("install")), EngineOperation.Status), "A stale unavailable status with actions was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(statusFailure, root => { root["ok"] = true; root["error"] = null; }), EngineOperation.Status), "A successful stale unavailable status was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(statusFailure, root => root["error"]!["code"] = "OPERATION_FAILED"), EngineOperation.Status), "A stale unavailable status with the wrong error was accepted.");
const string unavailableStatus = "{\"schemaVersion\":1,\"ok\":true,\"operation\":\"status\",\"state\":{\"install\":\"not-installed\",\"codex\":\"stopped\",\"session\":\"official\",\"operation\":\"idle\",\"themeName\":\"午夜极光\",\"requiresRestart\":false,\"availableActions\":[\"install\"],\"verified\":null},\"error\":null}";
Assert(EngineProtocol.Parse(unavailableStatus, EngineOperation.Status).State.ThemeName == "午夜极光", "The Task 7 unavailable-engine status was rejected.");
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(unavailableStatus, root => root["state"]!["availableActions"] = new JsonArray()), EngineOperation.Status), "A successful unavailable status without install recovery was accepted.");
var unavailableCodexError = Mutate(unavailableStatus, root =>
{
  root["ok"] = false;
  root["state"]!["codex"] = "not-installed";
  root["error"] = JsonNode.Parse("{\"code\":\"CODEX_NOT_INSTALLED\",\"message\":\"Codex is not installed.\",\"recoveryActions\":[\"cancel\"]}");
});
Assert(EngineProtocol.Parse(unavailableCodexError, EngineOperation.Status).Error?.Code == "CODEX_NOT_INSTALLED", "The unavailable-engine Codex error projection was rejected.");

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

var progress = new List<EngineProgress>();
EngineProtocol.ParseProgress("DREAM_SKIN_PROGRESS checking\r\nDREAM_SKIN_PROGRESS applying\r\n", new InlineProgress<EngineProgress>(progress.Add));
Assert(progress.SequenceEqual(new[] { EngineProgress.Checking, EngineProgress.Applying }), "Progress chunks were not parsed.");
Throws<InvalidDataException>(() => EngineProtocol.ParseProgress("raw error\n", null), "Raw stderr was accepted.");
Throws<InvalidDataException>(() => EngineProtocol.ParseProgress("DREAM_SKIN_PROGRESS mystery\n", null), "Unknown progress was accepted.");

var invalidRequest = Mutate(restartRequired, root =>
{
  root["state"] = JsonNode.Parse("{\"install\":\"not-installed\",\"codex\":\"not-installed\",\"session\":\"official\",\"operation\":\"idle\",\"themeName\":null,\"requiresRestart\":false,\"availableActions\":[],\"verified\":null}");
  root["error"]!["code"] = "INVALID_REQUEST";
  root["error"]!["recoveryActions"] = new JsonArray("cancel");
});
Throws<InvalidDataException>(() => EngineProtocol.Parse(Mutate(invalidRequest, root => root["state"]!["availableActions"] = new JsonArray("install")), EngineOperation.Apply), "INVALID_REQUEST with a non-empty state projection was accepted.");
foreach (var accepted in new[] { new EngineProcessResult(0, valid, ""), new EngineProcessResult(1, restartRequired, ""), new EngineProcessResult(2, invalidRequest, "") })
  Assert((await new EngineClient(new FakeRunner(accepted), "C:\\Windows").RunAsync(EngineOperation.Apply, deep: false)).SchemaVersion == 1, $"Valid exit {accepted.ExitCode} was rejected.");
await ThrowsAsync<InvalidDataException>(async () => await new EngineClient(new FakeRunner(new EngineProcessResult(1, invalidRequest, "")), "C:\\Windows").RunAsync(EngineOperation.Apply, deep: false), "INVALID_REQUEST at exit 1 was accepted.");
await ThrowsAsync<InvalidDataException>(async () => await new EngineClient(new FakeRunner(new EngineProcessResult(2, restartRequired, "")), "C:\\Windows").RunAsync(EngineOperation.Apply, deep: false), "Domain error at exit 2 was accepted.");
Assert((await new EngineClient(new FakeRunner(new EngineProcessResult(1, statusFailure, "")), "C:\\Windows").RunAsync(EngineOperation.Status, deep: true)).Error?.Code == "INTERNAL_ERROR", "The Task 7 status failure was not accepted at exit 1.");
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
