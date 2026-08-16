import { defineConfig, loadEnv } from 'vite';
import react from '@vitejs/plugin-react';

// 管理 SPA 部署在 HTTPS 站点的 /panel/ 路径（Caddy 托管）。
// base 设为 /panel/，保证构建产物的资源路径正确。
// 开发时 vite dev server 将 /api 代理到本地 FastAPI。
export default defineConfig(({ mode }) => {
  // loadEnv 读取 .env / .env.local 与真实进程环境，取 VITE_DEV_PROXY_TARGET
  const env = loadEnv(mode, process.cwd(), '');
  const proxyTarget = env.VITE_DEV_PROXY_TARGET || 'http://127.0.0.1:18080';

  return {
    base: '/panel/',
    plugins: [react()],
    server: {
      port: 5173,
      proxy: {
        '/api': {
          // 本地后端默认 18080，可用 VITE_DEV_PROXY_TARGET 覆盖（如后端在其它端口）
          target: proxyTarget,
          changeOrigin: true,
        },
      },
    },
    build: {
      outDir: 'dist',
      chunkSizeWarningLimit: 2500,
      rollupOptions: {
        output: {
          // 供应商分包：减少首屏并发、便于浏览器长缓存
          manualChunks: {
            react: ['react', 'react-dom', 'react-router-dom'],
            antd: ['antd', '@ant-design/icons'],
            pro: ['@ant-design/pro-components'],
            axios: ['axios'],
          },
        },
      },
    },
  };
});
