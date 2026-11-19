const path = require('node:path');
require('@next/env').loadEnvConfig(process.cwd());
const value = process.env.DATABASE_URL;
// Prisma 的相对 SQLite 路径以 schema 所在目录为准，standalone 模式也保持一致。
if (value && value.startsWith('file:') && !path.isAbsolute(value.slice(5))) {
  process.env.DATABASE_URL = 'file:' + path.resolve(process.cwd(), 'prisma', value.slice(5));
}
require(path.resolve(process.cwd(), '.next/standalone/server.js'));
