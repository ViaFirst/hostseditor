# HostsEditor — notes for Claude

- Built to the **mac-app** standard (`~/.claude/skills/mac-app`): run `/mac-app HostsEditor audit`
  before larger changes; follow its invariants (EN + RU + HE via `L()`, key codes for shortcuts,
  self-tests, stable signing, CHANGELOG + `scripts/bump-version.sh`).
- Distribution channel: personal
- Git: private on ViaFirst (not created yet)
- Build/install: `./build.sh install`. Tests: `--self-test`, `--render-test <png>`.
- Kind: window + menu-bar (`LSUIElement` YES; Dock icon only while the window is open).
- Writing: `HostsWriter` → `do shell script … with administrator privileges` (cat into the resolved
  `/private/etc/hosts`, keeps owner/mode), then `dscacheutil -flushcache` + `killall -HUP mDNSResponder`.
  App Store is impossible (sandbox can't write /etc/hosts).
- Tests must never write the real hosts file: they use temp files / `HOSTSEDITOR_FILE`.
- Render test uses `layer.render` (cacheDisplay misses search field and buttons on macOS 27).
