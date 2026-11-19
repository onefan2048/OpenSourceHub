FROM node:22-bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends openssl ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1 DATABASE_URL=file:/app/data/hub.db
COPY package.json package-lock.json ./
COPY prisma/schema.prisma ./prisma/schema.prisma
RUN npm ci && npx prisma generate
COPY . .
RUN mkdir -p /app/data && npm run build
EXPOSE 3000
CMD ["npm", "start"]
