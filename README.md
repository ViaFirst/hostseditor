# HostsEditor

Edit `/etc/hosts` comfortably: a table of entries with on/off checkboxes, drag-to-reorder,
add and delete, plus a menu-bar menu for switching entries on and off quickly.

## Features

- Table: checkbox · IP address · hostnames · comment. Comment lines show as their own rows.
- Drag rows to reorder (several at once); Space toggles the selected rows, ⌫ deletes them.
- Sort (bottom-bar ⇅ or the Entries menu): by domain, by IP, enabled first — inside each comment-delimited
  group, so blocks like LocalWP's `## Local - Start ##` stay together. Remove Duplicates. All undoable.
- Add entry ⌘N, add comment ⇧⌘N, search ⌘F, undo/redo ⌘Z / ⇧⌘Z.
- Changes stay pending until **Apply** (⌘S): one admin password / Touch ID prompt, then the DNS cache is flushed.
- Before every write the current file is backed up to `~/Library/Application Support/HostsEditor/Backups/`
  (last 30; `defaults write com.viafirst.hostseditor backupLimit -int 50` to change).
- Untouched lines are written back byte for byte; the header comment block is kept.
- System lines (`127.0.0.1 localhost`, `255.255.255.255 broadcasthost`, `::1 localhost`) are protected.
- Invalid IPs / hostnames are shown in red and block Apply; edits made by another app are detected before writing.
- Menu-bar menu: sections from comments, A–Z, one item per site (its 127.0.0.1 / ::1 and www. lines merged),
  IP as a subtitle; a site with several server IPs gets a submenu to pick one. A switch there is applied
  immediately (cancelled password → switch undone). `HostsEditor --menu-dump` prints this menu for the real file.

## Build

```bash
./build.sh install     # builds, signs, installs to ~/Applications and launches
```

Self-tests (never touch the real `/etc/hosts`):
`build/HostsEditor.app/Contents/MacOS/HostsEditor --self-test`,
`--render-test out.png [-AppleLanguages "(he)"]`.
`HOSTSEDITOR_FILE=/path/to/file` makes the app edit another file (no admin prompt if it is writable).

Languages: English, Russian, Hebrew (RTL).

## License

MIT, see [LICENSE](LICENSE).
