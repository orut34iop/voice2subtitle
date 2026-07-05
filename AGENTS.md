# Project Rules

These rules apply to all future work in this repository.

- After any code modification, finish the change by committing and pushing it promptly. Keep commits scoped to the files changed for the task, and do not include unrelated worktree changes.
- Every build performed by the assistant must include the build date and time in the app version/build metadata. Use the local build time in `yyyyMMddHHmm` format unless the user specifies another format, and keep the Xcode project version fields and `Sources/V2SApp/App/AppModel.swift` in sync.
- After every modification, rebuild the macOS arm64 app, install the rebuilt `v2s.app` into `/Applications`, and verify that it launches normally before reporting the task as complete.
