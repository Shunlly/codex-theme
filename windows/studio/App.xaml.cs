using System.IO;
using System.Security.Principal;
using System.Windows;

namespace CodexDreamSkinStudio;

public partial class App : System.Windows.Application
{
  private SingleInstanceCoordinator? _singleInstance;

  protected override void OnStartup(StartupEventArgs e)
  {
    base.OnStartup(e);
    var prepareUninstall = e.Args.Length == 1 && e.Args[0].Equals("--prepare-uninstall", StringComparison.Ordinal);
    if (e.Args.Length != 0 && !prepareUninstall)
    {
      Shutdown(1);
      return;
    }
    var user = WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
    _singleInstance = new SingleInstanceCoordinator(user);
    if (!_singleInstance.TryAcquireOwnership())
    {
      try
      {
        var command = prepareUninstall ? "prepare-uninstall" : "activate";
        var response = _singleInstance.ForwardAsync(command, Environment.ProcessPath ?? String.Empty,
          TimeSpan.FromSeconds(15), prepareUninstall ? null : TimeSpan.FromSeconds(15)).GetAwaiter().GetResult();
        if (!prepareUninstall && response.ExitCode == 0 && response.ReleaseOwner)
        {
          if (!_singleInstance.TryAcquireOwnership())
          {
            Shutdown(1);
            return;
          }
        }
        else
        {
          Shutdown(response.ExitCode);
          return;
        }
      }
      catch
      {
        Shutdown(1);
        return;
      }
    }

    var window = new MainWindow(prepareUninstall);
    MainWindow = window;
    _singleInstance.StartServer(HandleInstanceRequestAsync, InstanceResponseCompleted);
    window.Show();
  }

  private Task<SingleInstanceResponse> HandleInstanceRequestAsync(
    SingleInstanceRequest request,
    CancellationToken cancellationToken)
  {
    return Dispatcher.InvokeAsync(async () =>
    {
      if (MainWindow is not MainWindow window) return new SingleInstanceResponse(1, Environment.ProcessId, false);
      if (request.Command == "activate")
      {
        if (!SameExecutable(request.ExecutablePath, Environment.ProcessPath))
        {
          var reserved = window.TryReserveHandoff();
          return new SingleInstanceResponse(reserved ? 0 : 1, Environment.ProcessId, reserved);
        }
        window.ActivateFromSecondInstance();
        return new SingleInstanceResponse(0, Environment.ProcessId, false);
      }
      if (request.Command == "prepare-uninstall")
      {
        var exitCode = await window.PrepareUninstallFromOwnerAsync(cancellationToken);
        return new SingleInstanceResponse(exitCode, Environment.ProcessId, exitCode == 0);
      }
      return new SingleInstanceResponse(1, Environment.ProcessId, false);
    }).Task.Unwrap();
  }

  private void InstanceResponseCompleted(SingleInstanceResponse response, bool delivered)
  {
    if (!response.ReleaseOwner) return;
    Dispatcher.BeginInvoke(() =>
    {
      if (MainWindow is not MainWindow window) return;
      if (delivered) window.ReleaseForHandoff();
      else window.CancelHandoffReservation();
    });
  }

  private static bool SameExecutable(string left, string? right)
  {
    if (String.IsNullOrWhiteSpace(left) || String.IsNullOrWhiteSpace(right)) return false;
    try { return Path.GetFullPath(left).Equals(Path.GetFullPath(right), StringComparison.OrdinalIgnoreCase); }
    catch { return false; }
  }

  protected override void OnExit(ExitEventArgs e)
  {
    _singleInstance?.Dispose();
    base.OnExit(e);
  }
}
