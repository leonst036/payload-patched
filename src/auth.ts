import NextAuth from "next-auth"
import { DrizzleAdapter } from "@auth/drizzle-adapter"
import type { Adapter } from "next-auth/adapters"
import Credentials from "next-auth/providers/credentials"
import { eq } from "drizzle-orm"
import { db } from "./db"
import * as schema from "./db/schema"
import { verifyPassword } from "./lib/password"

const drizzleAdapter = DrizzleAdapter(db, {
  usersTable: schema.users,
  accountsTable: schema.accounts,
  sessionsTable: schema.sessions,
  verificationTokensTable: schema.verificationTokens,
})

export const { handlers, auth, signIn, signOut } = NextAuth({
  adapter: drizzleAdapter as Adapter,
  session: {
    strategy: "jwt",
  },
  providers: [
    Credentials({
      name: "Username and password",
      credentials: {
        username: { label: "Username", type: "text" },
        password: { label: "Password", type: "password" },
      },
      async authorize(credentials) {
        const username = typeof credentials.username === "string" ? credentials.username.trim().toLowerCase() : "";
        const password = typeof credentials.password === "string" ? credentials.password : "";
        if (!username || !password) return null;

        try {
          const user = await db.query.users.findFirst({
            where: eq(schema.users.username, username),
          });
          if (!user?.passwordHash) {
            console.warn(`[auth] unknown username: ${username}`);
            return null;
          }
          if (!(await verifyPassword(password, user.passwordHash))) {
            console.warn(`[auth] password mismatch for username: ${username}`);
            return null;
          }

          return {
            id: user.id,
            name: user.name ?? user.username,
            image: user.image,
            username: user.username,
            isAdmin: user.isAdmin,
          };
        } catch (error) {
          console.error("[auth] credentials authorization failed", error);
          return null;
        }
      },
    }),
  ],
  callbacks: {
    async jwt({ token, user }) {
      if (user) {
        token.id = user.id;
        token.username =
          "username" in user && typeof user.username === "string"
            ? user.username
            : null;
        token.isAdmin =
          "isAdmin" in user && typeof user.isAdmin === "boolean"
            ? user.isAdmin
            : false;
      }
      return token;
    },
    async session({ session, token }) {
      if (session.user) {
        session.user.id =
          typeof token.id === "string"
            ? token.id
            : typeof token.sub === "string"
              ? token.sub
              : "";
        (session.user as typeof session.user & {
          username?: string | null;
          isAdmin?: boolean;
        }).username =
          typeof token.username === "string" ? token.username : null;
        (session.user as typeof session.user & {
          username?: string | null;
          isAdmin?: boolean;
        }).isAdmin =
          typeof token.isAdmin === "boolean" ? token.isAdmin : false;
      }
      return session;
    },
  },
})
