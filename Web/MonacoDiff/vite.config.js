import { defineConfig } from 'vite';
import { resolve } from 'node:path';

export default defineConfig({
  base: './',
  publicDir: false,
  build: {
    assetsDir: '.',
    emptyOutDir: true,
    outDir: resolve(__dirname, '../../NeatGitApp/Resources/MonacoDiff')
  }
});
