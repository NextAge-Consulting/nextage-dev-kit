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
    rolldownOptions: {
      input: resolve(import.meta.dirname, "feed.css"),
      // The stylesheet is feed.css; anything else it pulls in, such as a font file an
      // @font-face names, goes under assets/ so it cannot take the stylesheet's name.
      output: { assetFileNames: ({ names }) => (names.some((n) => n.endsWith(".css")) ? "feed.css" : "assets/[name]-[hash][extname]") },
    },
  },
});
