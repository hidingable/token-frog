# Build context: this directory after npm run prepare:image-content (see README "Deploying").
FROM node:22.12.0-alpine AS build
# Mainland hosts can pass --build-arg NPM_REGISTRY=https://registry.npmmirror.com
ARG NPM_REGISTRY=https://registry.npmjs.org
ENV NPM_CONFIG_REGISTRY=$NPM_REGISTRY
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY tsconfig.json ./
COPY src ./src
COPY scripts ./scripts
COPY test ./test
RUN npm run build

FROM node:22.12.0-alpine
ARG NPM_REGISTRY=https://registry.npmjs.org
ENV NPM_CONFIG_REGISTRY=$NPM_REGISTRY
ENV NODE_ENV=production HOST=0.0.0.0 PORT=7321 HUB_TAGS_FILE=/app/tags.json
ENV HUB_PUBLISHED_IDS_FILE=/app/published-ids.txt HUB_CITIES_FILE=/app/cities.txt HUB_PETS_FILE=/app/pets.json
ENV HUB_ITEMS_FILE=/app/published-ids.txt
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund && npm cache clean --force
COPY --from=build /app/dist ./dist
COPY migrations ./migrations
COPY tags.json ./tags.json
COPY published-ids.txt cities.txt pets.json ./
USER node
EXPOSE 7321
CMD ["node", "dist/src/server.js"]
