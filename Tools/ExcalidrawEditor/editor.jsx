import React, { useState, useEffect } from "react";
import { createRoot } from "react-dom/client";
import { Excalidraw, MainMenu, restore, serializeAsJSON } from "@excalidraw/excalidraw";
import "@excalidraw/excalidraw/index.css";
import "./editor.css";

window.EXCALIDRAW_ASSET_PATH = new URL("./", location.href).href;
const send = (body) => window.webkit?.messageHandlers.dboardDrawing.postMessage(body);
let api = null;
let baseline = null;
let loading = false;
let revision = 0;
let lastDirty = false;
let setScene = null;
let sceneID = 0;

// Ignore view/selection and other transient state. Deletions and style changes remain edits.
const signature = (elements, appState, files) => JSON.stringify({
  elements: elements.map(({ updated, ...element }) => element),
  viewBackgroundColor: appState.viewBackgroundColor,
  gridSize: appState.gridSize ?? null,
  files,
});
const current = () => signature(api.getSceneElementsIncludingDeleted(), api.getAppState(), api.getFiles());
function change(elements, appState, files) {
  if (!api || loading || baseline === null) return;
  const dirty = signature(elements, appState, files) !== baseline;
  revision++;
  if (dirty !== lastDirty) { lastDirty = dirty; send({ type: "dirty", dirty }); }
}
window.dboardDrawing = {
  load(document) {
    loading = true; baseline = null; lastDirty = false;
    const scene = restore(document, null, null);
    setScene({ scene, id: ++sceneID });
  },
  snapshot() {
    const elements = api.getSceneElementsIncludingDeleted();
    const document = JSON.parse(serializeAsJSON(elements, api.getAppState(), api.getFiles(), "local"));
    // The library's export serializer discards deleted elements. A native document
    // keeps them, so opening and saving an existing scene preserves its records.
    document.elements = elements;
    return { json: JSON.stringify(document), signature: current(), revision };
  },
  saved(savedSignature) {
    baseline = savedSignature;
    lastDirty = current() !== baseline;
    send({ type: "dirty", dirty: lastDirty });
    return lastDirty;
  },
  fit() { api?.scrollToContent(api.getSceneElements(), { fitToContent: true, viewportZoomFactor: 0.92 }); },
};
function Editor() {
  const [scene, updateScene] = useState(null);
  setScene = updateScene;
  useEffect(() => { send({ type: "ready" }); }, []);
  if (!scene) return null;
  return <Excalidraw key={scene.id} initialData={{ ...scene.scene, scrollToContent: true }}
    langCode="zh-CN" detectScroll={false}
    excalidrawAPI={(instance) => {
      api = instance;
      // Excalidraw restores fields before exposing a stable scene to onChange.
      setTimeout(() => {
        if (api !== instance) return;
        baseline = current(); loading = false;
        window.dboardDrawing.fit();
        send({ type: "loaded", elementCount: api.getSceneElements().length });
      }, 100);
    }}
    onChange={change}
    UIOptions={{ canvasActions: { loadScene: false, saveToActiveFile: false,
      export: false, saveAsImage: false }, tools: { image: true } }}
    renderEmbeddable={() => null}>
    <MainMenu>
      <MainMenu.Item onSelect={() => send({ type: "save" })}>保存到原文件 ⌘S</MainMenu.Item>
      <MainMenu.DefaultItems.ChangeCanvasBackground />
      <MainMenu.DefaultItems.ToggleTheme />
      <MainMenu.DefaultItems.ClearCanvas />
      <MainMenu.DefaultItems.Help />
    </MainMenu>
  </Excalidraw>;
}
createRoot(document.getElementById("root")).render(<Editor />);
document.addEventListener("keydown", (event) => {
  if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "s") {
    event.preventDefault(); event.stopImmediatePropagation(); send({ type: "save" });
  }
}, true);
// Scene replacement belongs to the native document workflow.
document.addEventListener("drop", (event) => {
  const files = [...(event.dataTransfer?.files ?? [])];
  if (files.some((file) => /\.(excalidraw|json)$/i.test(file.name))) {
    event.preventDefault(); event.stopImmediatePropagation();
    send({ type: "notice", message: "请通过 D板的“打开绘图”打开另一个源文件。" });
  }
}, true);
window.addEventListener("error", (event) => send({ type: "error", message: event.message }));
window.addEventListener("unhandledrejection", (event) => send({ type: "error", message: String(event.reason) }));
