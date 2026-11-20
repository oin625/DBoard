import { build } from "esbuild";
import { cp, mkdir, readFile, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(fileURLToPath(import.meta.url));
const output = resolve(root, "../../Resources/ExcalidrawEditor");
const inputs = ["package.json", "package-lock.json", "editor.jsx", "editor.css", "index.html", "build.mjs"];
const hash = createHash("sha256");
for (const input of inputs) hash.update(await readFile(resolve(root, input)));
const stamp = hash.digest("hex");
if (await readFile(resolve(output, ".build-stamp"), "utf8").catch(() => "") !== stamp) {
  await mkdir(output, { recursive: true });
  await build({
    entryPoints: [resolve(root, "editor.jsx")], bundle: true, minify: true,
    outfile: resolve(output, "editor.js"), format: "iife", target: "safari17", conditions: ["production"],
    define: { "process.env.NODE_ENV": '"production"' },
    loader: { ".woff2": "file", ".woff": "file", ".ttf": "file", ".svg": "dataurl", ".png": "dataurl" },
    assetNames: "assets/[name]-[hash]",
  });
  await cp(resolve(root, "index.html"), resolve(output, "index.html"));
  await cp(resolve(root, "node_modules/@excalidraw/excalidraw/dist/prod/fonts"), resolve(output, "fonts"), { recursive: true });
  await cp(resolve(root, "LICENSE-Excalidraw"), resolve(output, "LICENSE"));
  await writeFile(resolve(output, ".build-stamp"), stamp);
}
