import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";
import { VitePWA } from "vite-plugin-pwa";

export default defineConfig({
  test: {
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
    css: false,
  },
  plugins: [
    react(),
    tailwindcss(),
    VitePWA({
      registerType: "autoUpdate",
      includeAssets: ["icon.svg", "icon-maskable.svg"],
      manifest: {
        name: "GitScope · Git 仓库分析",
        short_name: "GitScope",
        description: "移动端 Git 图谱与工程数据分析应用",
        theme_color: "#080d0b",
        background_color: "#080d0b",
        display: "standalone",
        orientation: "portrait-primary",
        start_url: "/",
        scope: "/",
        lang: "zh-CN",
        categories: ["developer", "productivity", "utilities"],
        icons: [
          { src: "/icon.svg", sizes: "any", type: "image/svg+xml", purpose: "any" },
          { src: "/icon-maskable.svg", sizes: "any", type: "image/svg+xml", purpose: "maskable" },
        ],
      },
      workbox: {
        navigateFallback: "/index.html",
        globPatterns: ["**/*.{js,css,html,svg,woff2}"],
        runtimeCaching: [
          {
            urlPattern: /^https:\/\/fonts\.googleapis\.com\//i,
            handler: "StaleWhileRevalidate",
            options: { cacheName: "google-font-stylesheets" },
          },
          {
            urlPattern: /^https:\/\/fonts\.gstatic\.com\//i,
            handler: "CacheFirst",
            options: { cacheName: "google-font-files", expiration: { maxEntries: 12, maxAgeSeconds: 31536000 } },
          },
        ],
      },
    }),
  ],
  server: { port: 4173 },
  build: {
    chunkSizeWarningLimit: 700,
    rollupOptions: {
      output: {
        manualChunks(id) {
          if (id.includes("echarts")) return "charts";
          if (id.includes("@phosphor-icons")) return "icons";
          if (id.includes("node_modules/react")) return "react";
        },
      },
    },
  },
});
