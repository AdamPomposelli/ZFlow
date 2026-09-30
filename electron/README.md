# ZFlow UI

An Electron front end for ZFlow's settings. The Swift app stays the engine —
audio capture, transcription, the hotkeys, the Accessibility work — and this is
the surface for configuring it.

```bash
npm install
npm run dev              # renderer only, in a browser, for layout work
npm start                # build and launch the Electron window
./scripts/package.sh     # assemble release/ZFlow UI.app
```

From the repository root, `make ui` does the install and the packaging, and a
following `make` copies the result into `ZFlow.app/Contents/Resources`. The
tray's Settings item then opens this window instead of the built-in one; the
native settings remain in the binary as a fallback for a build shipped without
the front end.

## How it reaches the app

The Swift app runs a loopback-only HTTP endpoint (`SettingsBridgeServer`) and
writes its port and a per-launch token to a 0600 handshake file in its
Application Support directory. This process reads that file and calls the
endpoint, so a change here goes through the same published properties the
native settings use and takes effect immediately.

Three things keep that surface small:

- the listener binds to `127.0.0.1` and is never reachable off the machine;
- every request needs the token, which is regenerated at each launch and
  readable only by the user;
- only the keys in `SettingsBridgeContract` can be read or written, so the
  endpoint cannot reach the API key or anything else in the app.

`GET /settings`, `POST /settings`, `GET /history` and `GET /dictionary` are the
whole API.

## Design

Tokens live in `src/styles/tokens.css`. The palette is warm: a cream shell, a
near-white content pane, and cards a shade *darker* than the pane rather than
lighter — that inversion is what gives the layout its papery feel.

Type is a transitional serif for page titles over a humanist sans for
everything else. The fonts here are freely available stand-ins loaded from
Google Fonts.
