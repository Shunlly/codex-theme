# Studio Engine Protocol v1

Every platform engine command returns this envelope:

```json
{
  "schemaVersion": 1,
  "ok": true,
  "operation": "status",
  "state": {
    "install": "ready",
    "codex": "running",
    "session": "active",
    "operation": "idle",
    "themeName": "午夜极光",
    "requiresRestart": false,
    "availableActions": ["pause", "restore"],
    "verified": true
  },
  "error": null
}
```

Fixed v1 values:

```text
operation: preflight | install | apply | status | pause | resume | restore | verify | uninstall
install: not-installed | ready
codex: not-installed | needs-first-run | stopped | running
session: official | active | paused | stale
operation state: idle | busy
verified: true | false | null
exit: 0 success | 1 domain error | 2 invalid request
progress: checking | preparing | installing | launching | connecting | applying | verifying | pausing | restoring | uninstalling
available action: install | apply | pause | resume | restore | verify | uninstall
recovery action: open-codex | authorize-restart | authorize-force-stop | retry | restore | diagnostics | cancel
error code: INVALID_REQUEST | OPERATION_BUSY | CODEX_NOT_INSTALLED | CODEX_FIRST_RUN_REQUIRED | CODEX_IDENTITY_INVALID | RUNTIME_INVALID | CODEX_CLOSE_REQUIRED | RESTART_REQUIRED | FORCE_STOP_REQUIRED | STATE_UNSAFE | PORT_UNAVAILABLE | CONFIG_UNSAFE | CONFIG_CHANGED | CONFIG_BACKUP_MISSING | THEME_INVALID | INJECTOR_FAILED | VERIFY_FAILED | LIVE_REMOVE_FAILED | OPERATION_FAILED | INTERNAL_ERROR
```

Errors set `ok` to `false` and provide `error.code`, a short `error.message`, and allowed `error.recoveryActions`. Successful responses set `error` to `null`.

`deleteUserThemes` is a non-envelope request option. It defaults to `false`, is valid only for `uninstall`, and returns `INVALID_REQUEST` for every other operation. Its platform spellings are `--delete-user-themes` on macOS and `-DeleteUserThemes` on Windows. Theme deletion is the final uninstall action, after restore, CDP closure, and engine cleanup eligibility have all succeeded.
