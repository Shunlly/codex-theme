using System.Security.Principal;
using System.Windows;

namespace CodexDreamSkinStudio;

public partial class App : System.Windows.Application
{
  private Mutex? _instanceMutex;

  protected override void OnStartup(StartupEventArgs e)
  {
    base.OnStartup(e);
    var user = WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
    _instanceMutex = new Mutex(true, $"Local\\CodexDreamSkinStudio.{user}", out var ownsInstance);
    if (!ownsInstance)
    {
      _instanceMutex.Dispose();
      _instanceMutex = null;
      Shutdown();
      return;
    }

    var window = new MainWindow();
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
