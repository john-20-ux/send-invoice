import { defineConfig, loadEnv } from "vite";
import react from "@vitejs/plugin-react-swc";
import path from "path";
import { componentTagger } from "lovable-tagger";

// https://vitejs.dev/config/
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), "");
  const apiPort = env.PORT || "3001";

  return {
    build: {
      rollupOptions: {
        output: {
          manualChunks(id) {
            if (id.includes("node_modules/jspdf")) {
              return "pdf-jspdf";
            }
            if (id.includes("node_modules/html2canvas")) {
              return "pdf-html2canvas";
            }
            if (id.includes("node_modules/html2pdf.js")) {
              return "pdf-html2pdf";
            }
            if (id.includes("node_modules/recharts")) {
              return "charts-recharts";
            }
            if (id.includes("node_modules/victory-vendor")) {
              return "charts-victory";
            }
            if (id.includes("node_modules/react-smooth")) {
              return "charts-anim";
            }
            if (/node_modules\/(d3-[^/]+|internmap)\//.test(id)) {
              return "charts-d3";
            }
            return undefined;
          },
        },
      },
    },
    server: {
      host: "::",
      port: 8080,
      hmr: {
        overlay: false,
      },
      proxy: {
        "/auth": `http://localhost:${apiPort}`,
        "/api": `http://localhost:${apiPort}`,
        "/health": `http://localhost:${apiPort}`,
      },
    },
    plugins: [react(), mode === "development" && componentTagger()].filter(Boolean),
    resolve: {
      alias: {
        "@": path.resolve(__dirname, "./src"),
      },
    },
  };
});
