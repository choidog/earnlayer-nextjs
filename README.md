# EarnLayer Next.js Migration

This is the Next.js/TypeScript migration of the EarnLayer backend, built for Railway deployment.

## Tech Stack

- **Next.js 15** (App Router)
- **TypeScript** 
- **Better Auth** for authentication
- **Drizzle ORM** with PostgreSQL
- **pgvector** for vector embeddings
- **OpenAI API** for embeddings and chat
- **Railway** for deployment

## Setup

1. Install dependencies:
```bash
npm install
```

2. Set up environment variables in `.env.local`:
```bash
DATABASE_URL="postgresql://user:pass@localhost:5432/earnlayer_db"
BETTER_AUTH_SECRET="your-secret-key"
BETTER_AUTH_URL="http://localhost:3000"
OPENAI_API_KEY="your-openai-key"
```

3. Generate and run database migrations:
```bash
npm run db:generate
npm run db:migrate
```

4. Start development server:
```bash
npm run dev
```

## Database Commands

- `npm run db:generate` - Generate migrations from schema
- `npm run db:migrate` - Apply migrations to database
- `npm run db:studio` - Open Drizzle Studio
- `npm run db:push` - Push schema directly (development only)

## Railway Deployment

1. Connect your GitHub repo to Railway
2. Add PostgreSQL service
3. Set environment variables
4. Deploy automatically on push

The app will be available at your Railway domain (e.g., `earnlayer-nextjs.railway.app`).
