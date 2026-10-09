FROM node:22-alpine

WORKDIR /app

# pnpm 必须钉版本：@latest 已到 11.x，未批准构建脚本（esbuild postinstall）
# 从警告升级为硬错误 ERR_PNPM_IGNORED_BUILDS，CI/服务器全新构建直接失败。
RUN corepack enable && corepack prepare pnpm@10.13.1 --activate

COPY package.json tsconfig.json .npmrc ./
RUN pnpm install --prod=false

COPY src/ ./src/
RUN pnpm build && pnpm prune --prod

EXPOSE 8080

# relay 与 watchdog 共用本镜像；watchdog 由 compose 覆盖 command
CMD ["node", "dist/index.js"]