# Flycom API — éles konténer.
#
# Alpine, és ez mérés, nem ízlés: a `better-sqlite3` 13.0.3 a csomagjában hozza
# a `linuxmusl-x64` és `linuxmusl-arm64` előre fordított binárist, tehát nem kell
# fordítói eszközkészlet a képbe. (Ha ez egy jövőbeli verzióban megszűnik, a
# tünet egy `node-gyp` hiba a build során — akkor ide `apk add --no-cache
# python3 make g++` kell a builder szakaszba.)
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev

FROM node:20-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY --from=builder /app/node_modules ./node_modules
COPY package*.json ./
COPY src/ ./src/
# Az admin parancs (produkció, első admin, felhasználók) a szerveren BELÜL fut:
# az API-n nincs regisztráció és produkció-létrehozás, és a képben nincs sqlite3.
COPY scripts/ ./scripts/

# Az adat a konténeren KÍVÜL él (compose-kötet). A könyvtárat azért kell
# létrehozni és átadni, mert az SQLite WAL módban a `.db` mellé `-wal` és `-shm`
# fájlt is ír: a KÖNYVTÁRNAK kell írhatónak lennie, nem csak a fájlnak.
RUN mkdir -p /var/lib/flycom && chown -R node:node /var/lib/flycom
USER node

EXPOSE 8080
CMD ["node", "src/index.js"]
