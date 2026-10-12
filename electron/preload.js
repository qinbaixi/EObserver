// Exposes the desktop-only features (self update) to the web UI.
const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('eobsDesktop', {
  platform: process.platform,
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
