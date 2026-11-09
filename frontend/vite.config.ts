import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { resolve } from "node:path";

/**
 * The vault frontend runs on port 5174 so it can coexist with the `amm-dex` frontend on 5173.
 */
export default defineConfig({
  root: resolve(__dirname),
  plugins: [react()],
  server: {
    port: 5174,
    strictPort: false,
    open: false,
  },
  build: {
    outDir: resolve(__dirname, "../dist"),
    emptyOutDir: true,
    sourcemap: true,
  },
  resolve: {
    alias: {
      "@": resolve(__dirname, "src"),
    },
  },
  define: {
    global: "globalThis",
  },
});
