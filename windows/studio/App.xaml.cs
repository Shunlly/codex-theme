using System.Security.Principal;
using System.Windows;

namespace CodexDreamSkinStudio;

public partial class App : System.Windows.Application
{
  private Mutex? _instanceMutex;

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
    _instanceMutex = new Mutex(true, $"Local\\CodexDreamSkinStudio.{user}", out var ownsInstance);
    if (!ownsInstance)
    {
      _instanceMutex.Dispose();
      _instanceMutex = null;
      if (prepareUninstall) Shutdown(1); else Shutdown();
      return;
    }

    var window = new MainWindow(prepareUninstall);
    MainWindow = window;
    window.Show();
  }

  protected override void OnExit(ExitEventArgs e)
  {
    if (_instanceMutex is not null)
    {
      try { _instanceMutex.ReleaseMutex(); } catch (ApplicationException) { }
      _instanceMutex.Dispose();
    }
    base.OnExit(e);
  }
}
