using System.Text;
using System.Text.Json;
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

foreach (var exitCode in new[] { 0, 1, 2 })
{
  var response = exitCode == 0 ? valid : fixtures.RootElement[6].GetProperty("response").GetRawText();
  var operation = exitCode == 0 ? EngineOperation.Apply : EngineOperation.Apply;
  var runner = new FakeRunner(new EngineProcessResult(exitCode, response, ""));
  var client = new EngineClient(runner, "C:\\Windows");
  var result = await client.RunAsync(operation, deep: false);
  Assert(result.SchemaVersion == 1, $"Domain envelope at exit {exitCode} was rejected.");
}
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
