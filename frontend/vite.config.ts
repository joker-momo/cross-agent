import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import path from "path";

// During dev, proxy API calls to the FastAPI backend on :7777.
export default defineConfig({
  plugins: [react()],
  resolve: {
    alias: { "@": path.resolve(__dirname, "src") },
  },
  server: {
    port: 5173,
    proxy: {
      "/projects": "http://127.0.0.1:7777",
      "/runs": "http://127.0.0.1:7777",
      "/run": "http://127.0.0.1:7777",
    },
  },
  build: { outDir: "dist" },
});
