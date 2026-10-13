// Builds the design system's feed stylesheet (design-system/feed.css) for the claude-design
// engine — the config's css.build. Vite with @tailwindcss/vite, the compiler the app already
// uses. Output goes to dist/, never into the app's own build.
import { resolve } from "node:path";
import tailwindcss from "@tailwindcss/vite";
import { defineConfig } from "vite";

export default defineConfig({
  root: resolve(import.meta.dirname, ".."),
  plugins: [tailwindcss()],
  logLevel: "warn",
  publicDir: false,
  build: {
    outDir: "dist/design-system-feed",
    emptyOutDir: true,
    sourcemap: false,
    rollupOptions: {
      input: resolve(import.meta.dirname, "feed.css"),
      output: { assetFileNames: "feed.css" },
    },
  },
});
