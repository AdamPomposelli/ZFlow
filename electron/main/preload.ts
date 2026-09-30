import { contextBridge, ipcRenderer, webUtils } from "electron";

contextBridge.exposeInMainWorld("zflow", {
  settings: () => ipcRenderer.invoke("bridge:settings"),
  edit: (action: string) => ipcRenderer.invoke("window:edit", action),
  windowAction: (action: string) => ipcRenderer.invoke("window:action", action),
  notetaker: {
    status: () => ipcRenderer.invoke("notetaker:status"),
    modelsReady: () => ipcRenderer.invoke("notetaker:modelsReady"),
    downloadModels: () => ipcRenderer.invoke("notetaker:downloadModels"),
    onModelProgress: (listener: (fraction: number) => void) => {
      const handler = (_event: unknown, fraction: number) => listener(fraction);
      ipcRenderer.on("notetaker:modelProgress", handler);
      return () => ipcRenderer.removeListener("notetaker:modelProgress", handler);
    },
    diarize: (wavPath: string) => ipcRenderer.invoke("notetaker:diarize", wavPath),
    request: () => ipcRenderer.invoke("notetaker:request"),
    start: () => ipcRenderer.invoke("notetaker:start"),
    chunk: (id: string, track: "mic" | "system", chunk: ArrayBuffer) =>
      ipcRenderer.invoke("notetaker:chunk", id, track, chunk),
    stop: (id: string) => ipcRenderer.invoke("notetaker:stop", id),
    meetings: (action: string, body: Record<string, unknown> = {}) =>
      ipcRenderer.invoke("notetaker:meetings", action, body),
  },
  write: (key: string, value: unknown) => ipcRenderer.invoke("bridge:write", key, value),
  history: () => ipcRenderer.invoke("bridge:history"),
  historyDelete: (id: string) => ipcRenderer.invoke("bridge:historyDelete", id),
  dictionary: () => ipcRenderer.invoke("bridge:dictionary"),
  status: () => ipcRenderer.invoke("bridge:status"),
  dictionaryMutate: (payload: Record<string, unknown>) =>
    ipcRenderer.invoke("bridge:dictionaryMutate", payload),
  microphones: () => ipcRenderer.invoke("bridge:microphones"),
  defaults: () => ipcRenderer.invoke("bridge:defaults"),
  screenshot: (id: string) => ipcRenderer.invoke("bridge:screenshot", id),
  insights: () => ipcRenderer.invoke("bridge:insights"),
  insightsReset: () => ipcRenderer.invoke("bridge:insightsReset"),
  permissions: () => ipcRenderer.invoke("bridge:permissions"),
  permissionRequest: (access: string) =>
    ipcRenderer.invoke("bridge:permissionRequest", access),
  transcribeFile: (filePath: string) => ipcRenderer.invoke("bridge:transcribeFile", filePath),
  // Electron stopped putting `path` on dropped File objects; this is the
  // supported way to get it, and it stays in the preload so the page itself
  // never gains the ability to resolve arbitrary files.
  filePath: (file: File) => webUtils.getPathForFile(file),
  transcribeFileStatus: (id: string) =>
    ipcRenderer.invoke("bridge:transcribeFileStatus", id),
  languages: () => ipcRenderer.invoke("bridge:languages"),
});
