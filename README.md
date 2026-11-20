# Payload

Ephemeral desktop VMs for Hack Club project reviewers. Reviewers log in, spin up a Linux/Windows/Android VM in the browser, and it auto-destroys after 6 hours or 30 minutes of inactivity.

## Getting Started

### Prerequisites

- Node.js 20 or newer
- pnpm
- Docker and Docker Compose
- A PostgreSQL database (the compose setup provides one)
- Redis (the compose setup provides one)
- Proxmox VE and an Apache Guacamole instance

### Local installation

1. Install dependencies:

   ```bash
   pnpm install
   ```

2. Create and configure the environment file:

   ```bash
   cp env.example .env
   ```

   Set `DATABASE_URL`, `REDIS_URL`, `PROXMOX_*`, `GUACAMOLE_*`, `SESSION_ENCRYPTION_KEY`, and `AUTH_SECRET`. The example file documents every setting and includes defaults where available.

3. Start PostgreSQL and Redis:

   ```bash
   docker compose up -d
   ```

4. Apply the database migrations and optionally seed demo data:

   ```bash
   pnpm db:migrate
   pnpm db:seed
   ```

5. Start Payload:

   ```bash
   pnpm dev
   ```

Open [http://localhost:3000](http://localhost:3000).

The first local account you register becomes the platform administrator. Register once through the sign-in page, then use the Admin panel to create workspaces and manage access.

## Scripts

- `pnpm dev` — Start dev server
- `pnpm build` — Build for production
- `pnpm lint` — Run linter
- `pnpm db:migrate` — Run database migrations
- `pnpm db:seed` — Seed database
- `pnpm db:generate` — Generate Drizzle migrations
