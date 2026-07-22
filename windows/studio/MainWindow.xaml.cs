using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using Forms = System.Windows.Forms;
using Drawing = System.Drawing;

namespace CodexDreamSkinStudio;

internal sealed class HandoffReservation
{
  internal bool IsActive { get; private set; }

  internal bool TryBegin(bool busy, bool confirming)
  {
    if (IsActive || busy || confirming) return false;
    IsActive = true;
    return true;
  }

  internal void Cancel() => IsActive = false;
}

public partial class MainWindow : Window
{
  private readonly EngineClient _client = new();
  private readonly Forms.NotifyIcon _tray;
  private readonly bool _prepareUninstall;
  private EngineEnvelope? _envelope;
  private bool _busy;
  private bool _confirming;
  private bool _preflightStarted;
  private bool _explicitExit;
  private bool _resourcesDisposed;
  private readonly HandoffReservation _handoff = new();

  public MainWindow(bool prepareUninstall = false)
  {
    _prepareUninstall = prepareUninstall;
    InitializeComponent();
    BoundToWorkArea(this, 580, 720);
    _tray = CreateTray();
    Loaded += async (_, _) => await InitializeAsync();
    StateChanged += (_, _) => { if (WindowState == WindowState.Minimized) Hide(); };
    UpdateView();
  }

  private async Task InitializeAsync()
  {
    if (_preflightStarted) return;
    _preflightStarted = true;
    if (_prepareUninstall)
    {
      var success = ConfirmPrepareUninstall() && await DispatchAsync(EngineOperation.Uninstall, bypassAvailability: true);
      FinishPrepareUninstall(success ? 0 : 1);
      return;
    }
    if (!await DispatchAsync(EngineOperation.Preflight) || _envelope is null) return;
    if (AutomaticOperation(_envelope.State.Session, _envelope.State.AvailableActions) is { } automaticOperation)
      await DispatchWithInstallFollowUpAsync(automaticOperation);
  }

  private Forms.NotifyIcon CreateTray()
  {
    var tray = new Forms.NotifyIcon
    {
      Icon = Drawing.SystemIcons.Application,
      Text = "Codex 梦幻皮肤",
      Visible = true,
      ContextMenuStrip = new Forms.ContextMenuStrip()
    };
    tray.DoubleClick += (_, _) => ShowWindow();
    tray.ContextMenuStrip.Items.Add("显示窗口", null, (_, _) => ShowWindow()).Name = "show";
    tray.ContextMenuStrip.Items.Add("应用主题", null,
      async (_, _) => await DispatchWithInstallFollowUpAsync(PrimaryOperation())).Name = "primary";
    tray.ContextMenuStrip.Items.Add("暂停", null, async (_, _) => await DispatchAsync(EngineOperation.Pause)).Name = "pause";
    tray.ContextMenuStrip.Items.Add("完全恢复", null, async (_, _) => await DispatchAsync(EngineOperation.Restore)).Name = "restore";
    tray.ContextMenuStrip.Items.Add(new Forms.ToolStripSeparator());
    tray.ContextMenuStrip.Items.Add("退出", null, async (_, _) => await ExitApplicationAsync()).Name = "exit";
    return tray;
  }

  private EngineOperation PrimaryOperation()
  {
    if (_envelope is not null) return PrimaryOperation(_envelope.State.Session, _envelope.State.AvailableActions);
    return EngineOperation.Apply;
  }

  internal static EngineOperation PrimaryOperation(string? session, IReadOnlyCollection<string> actions)
  {
    if (actions.Contains("install")) return EngineOperation.Install;
    if (session == "paused" && actions.Contains("resume")) return EngineOperation.Resume;
    return EngineOperation.Apply;
  }

  internal static EngineOperation? AutomaticOperation(string? session, IReadOnlyCollection<string> actions)
  {
    if (session is "paused" or "active") return null;
    if (actions.Contains("install") && !actions.Contains("restore")) return EngineOperation.Install;
    if (actions.Contains("apply")) return EngineOperation.Apply;
    return null;
  }

  internal static bool ShouldApplyAfterInstall(EngineOperation operation, string? preInstallSession, bool applyAvailable) =>
    operation == EngineOperation.Install && preInstallSession == "official" && applyAvailable;

  private bool CanRun(EngineOperation operation)
  {
    if (!AllowsDispatch(_busy, _confirming, _handoff.IsActive)) return false;
    if (_envelope is null) return operation == EngineOperation.Preflight;
    var action = operation.ToArgument();
    return _envelope.State.AvailableActions.Contains(action) ||
      operation == EngineOperation.Restore && _envelope.Error?.RecoveryActions.Contains("restore") == true;
  }

  internal static bool AllowsDispatch(bool busy, bool confirming, bool handoffReserved) =>
    !busy && !confirming && !handoffReserved;
  internal static bool AllowsTermination(bool busy, bool handoffReserved = false) => !busy && !handoffReserved;
  internal static bool AllowsRefresh(bool busy, bool confirming, bool handoffReserved = false) =>
    AllowsDispatch(busy, confirming, handoffReserved);
  internal bool CanReleaseForHandoff => AllowsDispatch(_busy, _confirming, _handoff.IsActive);

  internal void ActivateFromSecondInstance() => ShowWindow();

  internal bool TryReserveHandoff()
  {
    if (!_handoff.TryBegin(_busy, _confirming)) return false;
    UpdateView();
    return true;
  }

  internal void CancelHandoffReservation()
  {
    _handoff.Cancel();
    UpdateView();
  }

  internal async Task<int> PrepareUninstallFromOwnerAsync(CancellationToken cancellationToken)
  {
    if (!CanReleaseForHandoff || cancellationToken.IsCancellationRequested) return 1;
    ShowWindow();
    if (!ConfirmPrepareUninstall()) return 1;
    if (cancellationToken.IsCancellationRequested) return 1;
    if (!await DispatchAsync(EngineOperation.Uninstall, bypassAvailability: true, cancellationToken: cancellationToken) ||
      cancellationToken.IsCancellationRequested) return 1;
    return TryReserveHandoff() ? 0 : 1;
  }

  internal void ReleaseForHandoff()
  {
    if (_handoff.IsActive) FinishPrepareUninstall(0);
  }

  private async Task<bool> RefreshStatusAsync()
  {
    if (!AllowsRefresh(_busy, _confirming, _handoff.IsActive)) return false;
    return await DispatchAsync(EngineOperation.Status, bypassAvailability: true);
  }

  private async Task<bool> DispatchWithInstallFollowUpAsync(EngineOperation operation)
  {
    var preInstallSession = _envelope?.State.Session;
    if (!await DispatchAsync(operation)) return false;
    if (ShouldApplyAfterInstall(operation, preInstallSession, CanRun(EngineOperation.Apply)))
      return await DispatchAsync(EngineOperation.Apply);
    return true;
  }

  private async Task<bool> DispatchAsync(EngineOperation operation, bool deleteUserThemes = false,
    bool bypassAvailability = false, CancellationToken cancellationToken = default)
  {
    if (!AllowsDispatch(_busy, _confirming, _handoff.IsActive)) return false;
    if (!bypassAvailability && !CanRun(operation)) return false;
    var restartAuthorized = false;
    var forceAuthorized = false;
    try
    {
      while (true)
      {
        var result = await RunOnceAsync(operation, restartAuthorized, forceAuthorized, deleteUserThemes, cancellationToken);
        _envelope = result;
        UpdateView();
        if (result.Ok)
        {
          ProgressText.Text = ResultText(operation);
          return true;
        }
        if (result.Error?.Code is "CODEX_CLOSE_REQUIRED" or "RESTART_REQUIRED" && !restartAuthorized)
        {
          if (!ConfirmRestart()) return false;
          restartAuthorized = true;
          continue;
        }
        if (result.Error?.Code == "FORCE_STOP_REQUIRED")
        {
          if (!restartAuthorized)
          {
            if (!ConfirmRestart()) return false;
            restartAuthorized = true;
            continue;
          }
          if (!forceAuthorized)
          {
            if (!ConfirmForce()) return false;
            forceAuthorized = true;
            continue;
          }
        }
        ProgressText.Text = DomainErrorText(result.Error?.Code);
        return false;
      }
    }
    catch (OperationCanceledException) { ProgressText.Text = "操作已取消。"; return false; }
    catch
    {
      ProgressText.Text = "操作未能完成。请打开诊断信息后重试。";
      System.Windows.MessageBox.Show(this, "操作未能完成。请打开诊断信息后重试。", "Codex 梦幻皮肤", MessageBoxButton.OK, MessageBoxImage.Warning);
      return false;
    }
    finally
    {
      _busy = false;
      OperationProgress.Visibility = Visibility.Hidden;
      UpdateView();
    }
  }

  private async Task<EngineEnvelope> RunOnceAsync(EngineOperation operation, bool restartAuthorized,
    bool forceAuthorized, bool deleteUserThemes, CancellationToken cancellationToken)
  {
    _busy = true;
    OperationProgress.Visibility = Visibility.Visible;
    ProgressText.Text = "正在准备…";
    UpdateView();
    var progress = new Progress<EngineProgress>(value => ProgressText.Text = ProgressTextFor(value));
    return await _client.RunAsync(operation, restartAuthorized, forceAuthorized, deleteUserThemes,
      deep: operation is EngineOperation.Preflight or EngineOperation.Status, progress: progress,
      cancellationToken: cancellationToken);
  }

  private bool ConfirmRestart()
  {
    _confirming = true;
    UpdateView();
    try
    {
      return System.Windows.MessageBox.Show(this, "需要先关闭并重新打开 Codex 才能继续。要继续吗？", "需要重新打开 Codex",
        MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes;
    }
    finally { _confirming = false; UpdateView(); }
  }

  private bool ConfirmPrepareUninstall()
  {
    _confirming = true;
    UpdateView();
    try
    {
      return System.Windows.MessageBox.Show(this, "卸载前必须先恢复 Codex 的标准外观。要继续吗？", "卸载梦幻皮肤",
        MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes;
    }
    finally { _confirming = false; UpdateView(); }
  }

  private bool ConfirmForce()
  {
    _confirming = true;
    UpdateView();
    try
    {
      return System.Windows.MessageBox.Show(this, "Codex 未能正常关闭。强制停止可能丢失尚未保存的内容。仍要继续吗？", "强制停止 Codex",
        MessageBoxButton.YesNo, MessageBoxImage.Error, MessageBoxResult.No) == MessageBoxResult.Yes;
    }
    finally { _confirming = false; UpdateView(); }
  }

  private void UpdateView()
  {
    var state = _envelope?.State;
    StatusText.Text = state is null ? "正在检查当前状态…" : StateText(state);
    ThemeText.Text = state?.ThemeName is { Length: > 0 } name ? $"主题：{name}" : "主题：尚未选择";
    StatusText.ToolTip = StatusText.Text;
    ThemeText.ToolTip = ThemeText.Text;
    AutomationProperties.SetHelpText(StatusText, StatusText.Text);
    AutomationProperties.SetHelpText(ThemeText, ThemeText.Text);
    PrimaryButton.Content = PrimaryOperation() switch
    {
      EngineOperation.Install => "安装梦幻皮肤",
      EngineOperation.Resume => "继续使用",
      _ => "应用主题"
    };
    PrimaryButton.IsEnabled = CanRun(PrimaryOperation());
    PauseButton.IsEnabled = CanRun(EngineOperation.Pause);
    VerifyButton.IsEnabled = CanRun(EngineOperation.Verify);
    RestoreButton.IsEnabled = CanRun(EngineOperation.Restore);
    UninstallButton.IsEnabled = CanRun(EngineOperation.Uninstall);
    DiagnosticsButton.IsEnabled = AllowsDispatch(_busy, _confirming, _handoff.IsActive);
    RefreshButton.IsEnabled = AllowsRefresh(_busy, _confirming, _handoff.IsActive);

    var highContrast = SystemParameters.HighContrast;
    VerificationLine.Background = highContrast ? System.Windows.SystemColors.HighlightBrush : state?.Verified switch
    {
      true => new SolidColorBrush(System.Windows.Media.Color.FromRgb(16, 124, 16)),
      false => new SolidColorBrush(System.Windows.Media.Color.FromRgb(154, 103, 0)),
      _ => new SolidColorBrush(System.Windows.Media.Color.FromRgb(0, 124, 131))
    };
    UninstallButton.Foreground = highContrast ? System.Windows.SystemColors.WindowTextBrush : new SolidColorBrush(System.Windows.Media.Color.FromRgb(196, 43, 28));
    AutomationProperties.SetHelpText(VerificationLine, state?.Verified == true ? "已验证" : "尚未验证");
    UpdateTray();
  }

  private void UpdateTray()
  {
    if (_tray.ContextMenuStrip is null) return;
    var primary = _tray.ContextMenuStrip.Items["primary"]!;
    primary.Text = PrimaryOperation() switch
    {
      EngineOperation.Install => "安装梦幻皮肤",
      EngineOperation.Resume => "继续使用",
      _ => "应用主题"
    };
    primary.Enabled = CanRun(PrimaryOperation());
    _tray.ContextMenuStrip.Items["pause"]!.Enabled = CanRun(EngineOperation.Pause);
    _tray.ContextMenuStrip.Items["restore"]!.Enabled = CanRun(EngineOperation.Restore);
    _tray.ContextMenuStrip.Items["exit"]!.Enabled = AllowsTermination(_busy, _handoff.IsActive);
  }

  private static string StateText(EngineState state)
  {
    if (state.Verified == true) return "已验证";
    return state.Session switch
    {
      "active" => "主题正在使用",
      "paused" => "主题已暂停，可随时继续",
      "stale" => "需要恢复后才能继续",
      _ when state.Install == "ready" => "已准备好",
      _ when state.Codex == "not-installed" => "未找到 Codex",
      _ when state.Codex == "needs-first-run" => "请先打开一次 Codex",
      _ => "尚未安装"
    };
  }

  private static string DomainErrorText(string? code) => code switch
  {
    "CODEX_NOT_INSTALLED" => "未找到 Codex。请先安装 Codex。",
    "CODEX_FIRST_RUN_REQUIRED" => "请先打开一次 Codex 并完成初始设置。",
    "STATE_UNSAFE" => "当前状态需要恢复。可以选择“完全恢复”。",
    "RUNTIME_INVALID" => "运行组件不可用。请打开诊断信息。",
    "VERIFY_FAILED" => "主题未通过验证。可以重试或完全恢复。",
    "OPERATION_BUSY" => "另一个操作正在进行，请稍后重试。",
    _ => "操作未能完成。请打开诊断信息后重试。"
  };

  private static string ProgressTextFor(EngineProgress progress) => progress switch
  {
    EngineProgress.Checking => "正在检查…",
    EngineProgress.Preparing => "正在准备…",
    EngineProgress.Installing => "正在安装…",
    EngineProgress.Launching => "正在打开 Codex…",
    EngineProgress.Connecting => "正在连接 Codex…",
    EngineProgress.Applying => "正在应用主题…",
    EngineProgress.Verifying => "正在验证主题…",
    EngineProgress.Pausing => "正在暂停主题…",
    EngineProgress.Restoring => "正在完全恢复…",
    EngineProgress.Uninstalling => "正在卸载…",
    _ => "正在处理…"
  };

  private static string ResultText(EngineOperation operation) => operation switch
  {
    EngineOperation.Pause => "主题已暂停。",
    EngineOperation.Restore => "Codex 已恢复为标准外观。",
    EngineOperation.Uninstall => "梦幻皮肤已卸载。",
    EngineOperation.Preflight or EngineOperation.Status => "状态检查完成。",
    _ => "操作已完成。"
  };

  private void ShowWindow()
  {
    Show();
    WindowState = WindowState.Normal;
    Activate();
    Focus();
  }

  private Task ExitApplicationAsync()
  {
    if (!AllowsTermination(_busy, _handoff.IsActive)) return Task.CompletedTask;
    _explicitExit = true;
    DisposeResources();
    System.Windows.Application.Current.Shutdown(_prepareUninstall ? 1 : 0);
    return Task.CompletedTask;
  }

  private void FinishPrepareUninstall(int exitCode)
  {
    _explicitExit = true;
    DisposeResources();
    System.Windows.Application.Current.Shutdown(exitCode);
  }

  private void DisposeResources()
  {
    if (_resourcesDisposed) return;
    _resourcesDisposed = true;
    _tray.Visible = false;
    _tray.Dispose();
  }

  protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
  {
    if (!_explicitExit && !AllowsTermination(_busy, _handoff.IsActive))
    {
      e.Cancel = true;
    }
    else if (!_prepareUninstall && !_explicitExit)
    {
      e.Cancel = true;
      Hide();
    }
    base.OnClosing(e);
  }

  protected override void OnClosed(EventArgs e)
  {
    DisposeResources();
    base.OnClosed(e);
    if (_prepareUninstall && !_explicitExit) System.Windows.Application.Current.Shutdown(1);
  }

  private async void PrimaryButton_Click(object sender, RoutedEventArgs e) =>
    await DispatchWithInstallFollowUpAsync(PrimaryOperation());
  private async void PauseButton_Click(object sender, RoutedEventArgs e) => await DispatchAsync(EngineOperation.Pause);
  private async void VerifyButton_Click(object sender, RoutedEventArgs e) => await DispatchAsync(EngineOperation.Verify);
  private async void RestoreButton_Click(object sender, RoutedEventArgs e) => await DispatchAsync(EngineOperation.Restore);
  private async void RefreshButton_Click(object sender, RoutedEventArgs e) => await RefreshStatusAsync();

  private void DiagnosticsButton_Click(object sender, RoutedEventArgs e)
  {
    try
    {
      var diagnostics = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "CodexDreamSkin");
      Directory.CreateDirectory(diagnostics);
      Process.Start(new ProcessStartInfo("explorer.exe") { UseShellExecute = false, ArgumentList = { diagnostics } });
    }
    catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or InvalidOperationException)
    {
      ShowSafeOperationFailure();
    }
  }

  private async void UninstallButton_Click(object sender, RoutedEventArgs e)
  {
    var confirmed = false;
    var deleteUserThemes = false;
    _confirming = true;
    UpdateView();
    try
    {
      var dialog = new UninstallDialog { Owner = this };
      confirmed = dialog.ShowDialog() == true;
      deleteUserThemes = dialog.DeleteUserThemes;
    }
    finally
    {
      _confirming = false;
      UpdateView();
    }
    if (confirmed) await DispatchAsync(EngineOperation.Uninstall, deleteUserThemes);
  }

  private void ShowSafeOperationFailure()
  {
    ProgressText.Text = "操作未能完成。请打开诊断信息后重试。";
    System.Windows.MessageBox.Show(this, "操作未能完成。请打开诊断信息后重试。", "Codex 梦幻皮肤", MessageBoxButton.OK, MessageBoxImage.Warning);
  }

  internal static void BoundToWorkArea(Window window, double preferredWidth, double preferredHeight)
  {
    var workArea = SystemParameters.WorkArea;
    window.MaxWidth = Math.Max(1, workArea.Width - 32);
    window.MaxHeight = Math.Max(1, workArea.Height - 32);
    window.Width = Math.Min(preferredWidth, window.MaxWidth);
    window.Height = Math.Min(preferredHeight, window.MaxHeight);
  }
}

internal sealed class UninstallDialog : Window
{
  private readonly System.Windows.Controls.CheckBox _deleteThemes;
  internal bool DeleteUserThemes => _deleteThemes.IsChecked == true;

  internal UninstallDialog()
  {
    Title = "卸载梦幻皮肤";
    MainWindow.BoundToWorkArea(this, 460, 260);
    ResizeMode = ResizeMode.CanResizeWithGrip;
    WindowStartupLocation = WindowStartupLocation.CenterOwner;
    _deleteThemes = new System.Windows.Controls.CheckBox
    {
      Content = "同时删除我的主题",
      IsChecked = false,
      Margin = new Thickness(0, 16, 0, 8),
      ToolTip = "删除个人主题后无法撤销"
    };
    AutomationProperties.SetName(_deleteThemes, "同时删除我的主题");
    var warning = new TextBlock { Text = "卸载会恢复标准外观。删除个人主题后无法撤销。", TextWrapping = TextWrapping.Wrap };
    var uninstall = new System.Windows.Controls.Button
    {
      Content = "卸载",
      Foreground = SystemParameters.HighContrast ? System.Windows.SystemColors.WindowTextBrush : new SolidColorBrush(System.Windows.Media.Color.FromRgb(196, 43, 28)),
      MinWidth = 88,
      IsDefault = false
    };
    uninstall.Click += (_, _) => { DialogResult = true; Close(); };
    var cancel = new System.Windows.Controls.Button { Content = "取消", MinWidth = 88, IsCancel = true };
    var buttons = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0) };
    buttons.Children.Add(cancel);
    buttons.Children.Add(uninstall);
    var content = new StackPanel { Margin = new Thickness(24) };
    content.Children.Add(warning);
    content.Children.Add(_deleteThemes);
    content.Children.Add(buttons);
    Content = new ScrollViewer
    {
      Content = content,
      VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
      HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled
    };
  }
}
