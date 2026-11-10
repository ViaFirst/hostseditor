# HostsEditor — notes for Claude

- Built to the **mac-app** standard (`~/.claude/skills/mac-app`): run `/mac-app HostsEditor audit`
  before larger changes; follow its invariants (EN + RU + HE via `L()`, key codes for shortcuts,
  self-tests, stable signing, CHANGELOG + `scripts/bump-version.sh`).
- Distribution channel: personal
- Git: private on ViaFirst (not created yet)
- Build/install: `./build.sh install`. Tests: `--self-test`, `--render-test <png>`.
