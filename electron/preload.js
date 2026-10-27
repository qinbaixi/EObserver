// Exposes the desktop-only features (self update, UI language, opening
// crash dumps by native dialog or drag & drop) to the web UI.
const { contextBridge, ipcRenderer, webUtils } = require('electron')

contextBridge.exposeInMainWorld('eobsDesktop', {
  platform: process.platform,
  setLocale: (locale) => ipcRenderer.send('locale:set', String(locale)),
  // A crash dump picked in the native open dialog: its path, or null.
  openDumpFile: () => ipcRenderer.invoke('dump:open'),
  // The local path of a File dropped on the page ('' if it has none).
  pathForFile: (file) => {
    try {
      return webUtils.getPathForFile(file)
    } catch {
      return ''
    }
  },
  update: {
    check: () => ipcRenderer.invoke('update:check'),
    download: () => ipcRenderer.invoke('update:download'),
    install: () => ipcRenderer.invoke('update:install'),
    onProgress: (cb) => {
      const listener = (_e, percent) => cb(percent)
      ipcRenderer.on('update:progress', listener)
      return () => ipcRenderer.removeListener('update:progress', listener)
    },
  },
})
