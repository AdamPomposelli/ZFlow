import { app, BrowserWindow, Menu, ipcMain, nativeTheme, session, desktopCapturer } from "electron";
import path from "node:path";
import {
  captureStatus,
  requestCapture,
  startRecording,
  stopRecording,
  writeChunk,
} from "./notetaker";
import { configureModelDirectory, diarize, downloadModels, modelsReady } from "./diarization";
import {
  mutateDictionary,
  readDictionary,
  readHistory,
  deleteHistoryEntry,
  readMicrophones,
  readDefaults,
  readScreenshot,
  readInsights,
  resetInsights,
  readPermissions,
  requestPermission,
  startFileTranscription,
  fileTranscriptionStatus,
  readLanguages,
  readSettings,
  status,
  writeSetting,
  meetings,
  quitApp,
} from "./settings-bridge";

/**
 * Quits ZFlow, not just this window.
 *
 * Command-Q on the settings window means quit the app, and the app is the
 * menu-bar process — this window is one of its surfaces. Asking it to go
 * first, then following, is what keeps the two from outliving each other.
 */
async function quitEverything(): Promise<void> {
  try {
    await quitApp();
  } catch {
    // The app may already be gone; this window still should be.
  }
  app.quit();
}

/**
 * The window's own commands, driven from the page.
 *
 * This window has no menu bar: it is an accessory process so ZFlow keeps a
 * single Dock icon, and macOS gives accessory apps no menu bar at all. That
 * takes every standard key equivalent with it — including Command-V, which is
 * how anyone pastes an API key. The page listens for the keys and calls these,
 * which is one path rather than two that could both fire on the same press.
 */
function wireWindowCommands(win: BrowserWindow): void {
  // A right-click menu too: a shortcut nobody is told about is not a way to
  // reach cut, copy and paste.
  win.webContents.on("context-menu", (_event, params) => {
    if (!params.isEditable && !params.selectionText) return;
    Menu.buildFromTemplate([
      { role: "cut", enabled: params.editFlags.canCut },
      { role: "copy", enabled: params.editFlags.canCopy },
      { role: "paste", enabled: params.editFlags.canPaste },
      { type: "separator" },
      { role: "selectAll" },
    ]).popup({ window: win });
  });
}

/**
 * Brings the settings window to the front, making one if it has gone.
 *
 * Ordering the window above the others and asking for focus are two separate
 * things, and both are needed: an accessory app is not frontmost just because
 * one of its windows was raised. The brief always-on-top is what puts it over
 * a window belonging to an app that is currently active — dropped again
 * immediately, because staying on top is not what was asked for.
 *
 * It asks once. Apps that keep grabbing focus back are a nuisance and this
 * will not become one of them.
 */
function revealWindow(): void {
  const existing = BrowserWindow.getAllWindows()[0];
  const win = existing ?? createWindow();
  if (win.isMinimized()) win.restore();
  if (!win.isVisible()) win.show();

  const wasOnTop = win.isAlwaysOnTop();
  win.setAlwaysOnTop(true, "floating");
  win.moveTop();
  win.setAlwaysOnTop(wasOnTop);

  app.focus({ steal: true });
  win.focus();
}

function createWindow() {
  const win = new BrowserWindow({
    width: 1040,
    height: 720,
    minWidth: 900,
    minHeight: 620,
    titleBarStyle: "hiddenInset",
    trafficLightPosition: { x: 18, y: 18 },
    backgroundColor: "#f2efe9",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  // An app with no Dock icon does not get focus for free: without this the
  // settings window can open behind whatever you were working in, which reads
  // as the tray item having done nothing.
  win.once("ready-to-show", () => {
    win.show();
    app.focus({ steal: true });
  });

  wireWindowCommands(win);

  const devServer = process.env.VITE_DEV_SERVER_URL;
  if (devServer) {
    win.loadURL(devServer);
  } else {
    win.loadFile(path.join(__dirname, "../dist/index.html"));
  }
  return win;
}

// Only one settings window, and a second launch reveals the first rather
// than opening another.
if (!app.requestSingleInstanceLock()) {
  app.quit();
} else {
  app.on("second-instance", revealWindow);
}

app.setAsDefaultProtocolClient("zflow");

// How ZFlow asks for the window when you click its Dock icon.
app.on("open-url", (event, url) => {
  event.preventDefault();
  if (app.isReady()) {
    revealWindow();
  } else {
    app.whenReady().then(revealWindow);
  }
  void url;
});

app.whenReady().then(() => {
  // One ZFlow in the Dock, not two. This window is ZFlow's settings, not an
  // app of its own, and a second icon beside the real one — an Electron logo,
  // at that — says otherwise. Hiding the icon keeps the default menu, so the
  // usual editing shortcuts still work in the text fields here.
  app.dock?.hide();

  // What lets the page capture what the machine is playing. macOS routes
  // system audio through the screen-capture permission, so this is also the
  // point at which it is asked for — when a recording starts, and never
  // before.
  session.defaultSession.setDisplayMediaRequestHandler(
    (_request, callback) => {
      desktopCapturer
        .getSources({ types: ["screen"] })
        .then((sources) => {
          if (!sources.length) {
            callback({});
            return;
          }
          callback({ video: sources[0], audio: "loopback" });
        })
        .catch(() => callback({}));
    },
    { useSystemPicker: false }
  );
  nativeTheme.themeSource = "light";

  // Beside the app's other data, so someone who wants the disk back knows
  // where to look.
  configureModelDirectory(path.join(app.getPath("userData"), "SpeakerModels"));

  ipcMain.handle("window:edit", (event, action: string) => {
    const contents = event.sender;
    switch (action) {
      case "copy": contents.copy(); return true;
      case "cut": contents.cut(); return true;
      case "paste": contents.paste(); return true;
      case "selectAll": contents.selectAll(); return true;
      case "undo": contents.undo(); return true;
      case "redo": contents.redo(); return true;
      default: return false;
    }
  });
  ipcMain.handle("window:action", async (event, action: string) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    switch (action) {
      case "close": win?.close(); return true;
      case "minimize": win?.minimize(); return true;
      case "quit": await quitEverything(); return true;
      default: return false;
    }
  });

  ipcMain.handle("notetaker:status", () => captureStatus());
  ipcMain.handle("notetaker:modelsReady", () => modelsReady());
  ipcMain.handle("notetaker:downloadModels", (event) =>
    downloadModels((fraction) => {
      event.sender.send("notetaker:modelProgress", fraction);
    })
  );
  ipcMain.handle("notetaker:diarize", (_event, wavPath: string) => diarize(wavPath));
  ipcMain.handle("notetaker:request", () => requestCapture());
  ipcMain.handle("notetaker:start", () => startRecording());
  ipcMain.handle("notetaker:chunk", (_event, id: string, track: "mic" | "system", chunk: ArrayBuffer) =>
    writeChunk(id, track, chunk)
  );
  ipcMain.handle("notetaker:stop", (_event, id: string) => stopRecording(id));
  ipcMain.handle("notetaker:meetings", (_event, action: string, body: Record<string, unknown>) =>
    meetings(action, body)
  );

  ipcMain.handle("bridge:settings", () => readSettings());
  ipcMain.handle("bridge:write", (_event, key: string, value: unknown) => writeSetting(key, value));
  ipcMain.handle("bridge:history", () => readHistory());
  ipcMain.handle("bridge:historyDelete", (_event, id: string) => deleteHistoryEntry(id));
  ipcMain.handle("bridge:dictionary", () => readDictionary());
  ipcMain.handle("bridge:status", () => status());
  ipcMain.handle("bridge:dictionaryMutate", (_e, payload: Record<string, unknown>) =>
    mutateDictionary(payload)
  );
  ipcMain.handle("bridge:microphones", () => readMicrophones());
  ipcMain.handle("bridge:defaults", () => readDefaults());
  ipcMain.handle("bridge:insights", () => readInsights());
  ipcMain.handle("bridge:insightsReset", () => resetInsights());
  ipcMain.handle("bridge:permissions", () => readPermissions());
  ipcMain.handle("bridge:permissionRequest", (_event, access: string) =>
    requestPermission(access),
  );
  ipcMain.handle("bridge:transcribeFile", (_event, filePath: string) =>
    startFileTranscription(filePath)
  );
  ipcMain.handle("bridge:transcribeFileStatus", (_event, id: string) =>
    fileTranscriptionStatus(id)
  );
  ipcMain.handle("bridge:screenshot", (_event, id: string) => readScreenshot(id));
  ipcMain.handle("bridge:languages", () => readLanguages());

  createWindow();
  app.on("activate", () => {
    // Belt and braces: if the process is somehow still here without a window,
    // being activated brings one back rather than doing nothing.
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
    BrowserWindow.getAllWindows()[0]?.show();
  });
});

app.on("window-all-closed", () => {
  // The window is the whole app here, so closing it ends the process — the
  // usual macOS habit of lingering does not apply.
  //
  // It is also the bug it fixes: a windowless process still counts as
  // running, so ZFlow would find it and activate it, and activating an app
  // with nothing to show looks exactly like the Dock icon doing nothing.
  app.quit();
});
