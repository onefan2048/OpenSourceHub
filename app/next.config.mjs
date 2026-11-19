import path from "node:path";
/** @type {import('next').NextConfig} */
const nextConfig = {
  output: "standalone",
  outputFileTracingRoot: process.cwd(),
  images: { unoptimized: true },
  serverExternalPackages: ["@prisma/client", ".prisma/client"],
  webpack(config) { config.resolve.alias["@"] = path.resolve(process.cwd(), "src"); return config; },
};
export default nextConfig;
