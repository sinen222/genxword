# Signal Secure Window – Windows

Gleiches Prinzip wie die Linux-Version: Signals Profil (`%APPDATA%\Signal`)
liegt in einem verschlüsselten **VeraCrypt-Container** und ist **nur
eingehängt, solange Signal läuft**.

```
Verknüpfung ──► VeraCrypt-Passwortdialog (sicherer Desktop) ──► Container auf S: ──► Signal
                                                                                  │
Signal beendet / Win+L / Inaktivität / "lock" ◄────────────────────────────────────┘
        │
        └──► Signal schließen ──► Container aushängen ──► Daten nur verschlüsselt
```

`%APPDATA%\Signal` wird zu einer Verzeichnisverbindung (Junction) auf
`S:\Signal`. Ist der Container gesperrt, zeigt sie ins Leere. Ein direkt
gestartetes Signal findet dann weder Chats noch Schlüssel und kann auch kein
neues, unverschlüsseltes Profil anlegen.

## Unterschied zur Linux-Version

Windows hat kein Gegenstück zu bubblewrap, das sich per Skript sinnvoll um eine
Electron-App legen lässt. Die Windows-Version schützt daher die **Daten im
Ruhezustand** (Tresor, Sperren bei Ende, Win+L und Inaktivität). Sie
**isoliert Signal aber nicht** vom Rest des Systems. Solange der Container
offen ist, kann jedes Programm deines Benutzers `S:` lesen.

## Voraussetzungen

- [VeraCrypt](https://veracrypt.fr) (normale Installation, nicht portabel)
- Signal Desktop (Standardinstallation unter `%LOCALAPPDATA%\Programs\signal-desktop`)
- Windows PowerShell 5.1 (vorinstalliert) oder PowerShell 7

## Einrichtung

1. Signal vollständig beenden (auch im Infobereich neben der Uhr).
2. In Signal unter *Einstellungen → Allgemein* **„Beim Anmelden starten“ ausschalten**.
3. PowerShell im Ordner des Skripts öffnen:
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\SignalSecureWindow.ps1 init
   ```
   Optionen: `-SizeGB 8` (Containergröße, Standard 4), `-DriveLetter S`,
   `-VaultPath D:\pfad\signal.hc`.
   Das vorhandene Profil wird in den Container kopiert, geprüft und danach
   gelöscht oder umbenannt (Rückfrage).
4. Verknüpfungen anlegen (Startmenü + Desktop):
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\SignalSecureWindow.ps1 install-shortcut
   ```
   Ab jetzt Signal nur noch über **„Signal (Secure Window)“** starten. Die
   alten Signal-Verknüpfungen am besten entfernen.

## Benutzung

| Befehl | Wirkung |
|---|---|
| `SignalSecureWindow.ps1` / `run` | entsperren, Signal starten, nach dem Ende sperren |
| `run -IdleMinutes 10` | zusätzlich nach 10 min ohne Eingabe sperren |
| `run -NoScreenLock` | bei Win+L **nicht** sperren |
| `lock` | Signal sofort schließen und Container sperren |
| `status` | Zustand anzeigen |

Die Inaktivitätszeit lässt sich dauerhaft setzen, indem man in den
Eigenschaften der Verknüpfung `-IdleMinutes 10` an das Ziel anhängt.

## Hinweise

- **„Im Infobereich minimieren“** hält Signal am Laufen. Der Container bleibt
  dann offen, bis Signal wirklich beendet, Win+L gedrückt oder `lock`
  ausgeführt wird.
- Das Passwort wird in VeraCrypts eigenem Dialog auf dem **sicheren Desktop**
  eingegeben, nicht zwischengespeichert (`/cache n`) und nicht im Verlauf
  gemerkt. Nur bei `init` übergibt das Skript das Passwort einmalig auf der
  Kommandozeile an VeraCrypt, weil VeraCrypt Format es nicht anders annimmt.
- Gelöschte Klartextdaten sind auf SSDs ggf. wiederherstellbar. Für vollen
  Schutz zusätzlich **BitLocker** bzw. Geräteverschlüsselung einschalten.
- Signal-Updates funktionieren normal. Das Programm selbst liegt außerhalb des
  Containers.
- Passwort ändern: über VeraCrypt (*Volumes → Volume-Passwort ändern*) bei
  gesperrtem Container.
