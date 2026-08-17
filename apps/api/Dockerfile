FROM node:24-alpine AS build
RUN apk add --no-cache git
WORKDIR /app
COPY package*.json ./
COPY apps/api/package.json apps/api/package.json
COPY packages/contracts/package.json packages/contracts/package.json
RUN npm ci
COPY apps/api apps/api
COPY packages/contracts packages/contracts
RUN npm run build -w @gitscope/contracts && npm run build -w @gitscope/api

FROM node:24-alpine
RUN apk add --no-cache git && addgroup -S gitscope && adduser -S gitscope -G gitscope \
    && mkdir -p /data && chown gitscope:gitscope /data
WORKDIR /app
COPY --from=build /app/node_modules ./node_modules
COPY --from=build /app/apps/api/dist ./apps/api/dist
COPY --from=build /app/apps/api/package.json ./apps/api/package.json
COPY --from=build /app/packages/contracts ./packages/contracts
USER gitscope
ENV NODE_ENV=production PORT=8080
EXPOSE 8080
CMD ["node", "apps/api/dist/server.js"]
