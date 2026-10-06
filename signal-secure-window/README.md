# Signal Secure Window

Ein „sicheres Fenster“ für **Signal Desktop unter Linux**: Signal läuft in einer
Sandbox, und sein komplettes Profil (Chats, Schlüssel, Anhänge, Einstellungen)
liegt in einem verschlüsselten Tresor. **Entschlüsselt wird nur, solange Signal
läuft.**

```
 Start ──► Passwort ──► Tresor einhängen ──► Signal in bwrap-Sandbox
                                                   │
 Ende / Bildschirmsperre / Inaktivität / lock ◄────┘
        │
        └──► Signal beenden ──► Tresor aushängen ──► Daten nur noch verschlüsselt
```

## Was es schützt

| Bedrohung | Schutz |
|---|---|
| Andere Programme (Malware, Infostealer) lesen `~/.config/Signal` aus, während Signal **nicht** läuft | Dort liegt nur ein leerer Platzhalter ohne Rechte; die Daten sind mit gocryptfs (AES-256-GCM) verschlüsselt. |
| Signals Datenbankschlüssel liegt im Klartext in `config.json` | Die Datei liegt jetzt selbst im verschlüsselten Tresor. |
| Gerät wird gesperrt/unbeaufsichtigt zurückgelassen | Bei Bildschirmsperre (und optional nach Inaktivität) wird Signal geschlossen und der Tresor gesperrt. |
| Signal (oder eine Lücke darin) liest andere Dateien in deinem Home | bubblewrap-Sandbox: Home ist ein leeres tmpfs, nur Profil und Downloads-Ordner sind sichtbar; System nur lesend; D-Bus gefiltert. |
| Versehentlicher Start von Signal ohne Schutz | Der Platzhalter `~/.config/Signal` hat Rechte `000`, Signal kann dort kein neues Klartext-Profil anlegen. |

**Nicht** geschützt: Angreifer, die *während* Signal läuft Code als dein Benutzer
ausführen (sie können z. B. per FUSE-Mount mitlesen oder Tastatureingaben
abgreifen), sowie Root. Der Tresor ersetzt keine Festplattenverschlüsselung.

## Voraussetzungen

```sh
# Debian/Ubuntu
sudo apt install gocryptfs fuse3 bubblewrap
# optional: gefilterter D-Bus, Bildschirmsperre, Passwortdialog, Inaktivität
sudo apt install xdg-dbus-proxy dbus-bin zenity xprintidle
```

Signal Desktop aus dem offiziellen `.deb`-Paket (`/opt/Signal`). Die Flatpak-
und Snap-Version bringen eine eigene Sandbox mit und werden nicht unterstützt.

## Einrichtung

1. Signal beenden.
2. Tresor anlegen und das vorhandene Profil übernehmen:
   ```sh
   ./signal-secure-window init
   ```
   Den angezeigten **Master-Key** offline aufbewahren – damit lässt sich der
   Tresor bei vergessenem Passwort wiederherstellen.
3. Startmenü-Eintrag ersetzen:
   ```sh
   ./signal-secure-window install-desktop
   ```
   Am besten das Skript vorher nach `~/.local/bin/` kopieren.

## Benutzung

```sh
signal-secure-window                 # entsperren, Signal starten, danach sperren
signal-secure-window --idle 10       # zusätzlich nach 10 min Inaktivität schließen
signal-secure-window lock            # sofort schließen und sperren
signal-secure-window status          # Zustand anzeigen
signal-secure-window passwd          # Tresor-Passwort ändern
```

Optionen für `run`:

| Option | Bedeutung |
|---|---|
| `--dbus filtered` | Standard. Über `xdg-dbus-proxy` nur Benachrichtigungen, Schlüsselbund, Tray und Portale. Ohne `xdg-dbus-proxy` gibt es keinen D-Bus. |
| `--dbus none` | Kein D-Bus (keine Benachrichtigungen/Tray). |
| `--dbus full` | Voller Session-Bus – bequemer, aber deutlich schwächere Sandbox. |
| `--no-screenlock` | Bei Bildschirmsperre **nicht** schließen. |
| `--idle MIN` | Nach `MIN` Minuten ohne Eingabe schließen (X11, `xprintidle`). |
| `--downloads DIR` / `--no-downloads` | Beschreibbarer Ordner für Anhänge (Standard `~/Downloads`). |
| `--no-chromium-sandbox` | Nur falls Signal in der Sandbox nicht startet (Electron-eigene Sandbox aus; bwrap bleibt aktiv). |
| `-- ARGS` | Weitere Argumente direkt an Signal. |

Umgebungsvariablen: `SSW_VAULT_DIR` (Tresor, Standard
`~/.local/share/signal-secure-window`), `SSW_SIGNAL_PROFILE` (Profilpfad in
der Sandbox, Standard `~/.config/Signal`), `SSW_SIGNAL_BIN`.

## Hinweise

- **„Im Tray minimieren“** in Signal hält die App am Laufen – der Tresor bleibt
  dann entsperrt, bis Signal wirklich beendet, der Bildschirm gesperrt oder
  `lock` ausgeführt wird. Für maximalen Schutz die Option ausschalten.
- Nachrichten kommen nur an, solange Signal läuft; beim nächsten Start wird
  synchronisiert (wie bei jedem Beenden von Signal).
- Signal verschlüsselt seinen Datenbankschlüssel ggf. zusätzlich über den
  System-Schlüsselbund. Mit `--dbus filtered` ist der Schlüsselbund erreichbar;
  mit `--dbus none` startet ein so eingerichtetes Profil evtl. nicht.
- Beim Löschen des alten Klartext-Profils wird `shred` verwendet; auf SSDs und
  Copy-on-Write-Dateisystemen (btrfs, ZFS) ist das keine Garantie. Wer sicher
  gehen will, nutzt zusätzlich Festplattenverschlüsselung (LUKS).
- Der entschlüsselte Mountpunkt liegt in `$XDG_RUNTIME_DIR` (tmpfs, nur für
  dich lesbar) und ist nur außerhalb der Sandbox als FUSE-Ansicht sichtbar,
  solange Signal läuft.
