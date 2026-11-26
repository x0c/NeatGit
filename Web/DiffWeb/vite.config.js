import { defineConfig } from 'vite';
import { fileURLToPath } from 'node:url';
import { resolve } from 'node:path';

// 页面目录；产物输出到应用内嵌资源目录。
const projectDirectory = fileURLToPath(new URL('.', import.meta.url));

export default defineConfig({
  // 资源一律相对路径引用，便于宿主用应用内自定义地址加载。
  base: './',
  publicDir: false,
  plugins: [
    {
      name: 'neatgit-plain-assets',
      // 打包工具会把入口脚本标成模块类型，这里改回延迟执行的普通脚本：
      // 自定义地址下按模块加载有兼容风险，普通脚本最稳妥，延迟执行保证页面结构先就位。
      transformIndexHtml: {
        order: 'post',
        handler(html) {
          return html
            .replace(/\s+crossorigin(?=[\s>])/g, '')
            .replace(/<script type="module" src="\.\/index\.js"><\/script>/, '<script defer src="./index.js"></script>');
        }
      }
    }
  ],
  build: {
    assetsDir: '.',
    // 构建前清空输出目录，避免残留旧文件。
    emptyOutDir: true,
    outDir: resolve(projectDirectory, '../../NeatGitApp/Resources/DiffWeb'),
    cssCodeSplit: false,
    // 不生成模块预加载相关代码。
    modulePreload: false,
    rollupOptions: {
      output: {
        // 打包成一个普通脚本（非模块），自定义地址下加载最稳妥。
        format: 'iife',
        inlineDynamicImports: true,
        entryFileNames: 'index.js',
        assetFileNames: '[name][extname]'
      }
    }
  }
});
