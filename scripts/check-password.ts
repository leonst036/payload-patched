import "dotenv/config";
import { eq } from "drizzle-orm";
import { db } from "../src/db";
import { users } from "../src/db/schema";
import { verifyPassword } from "../src/lib/password";

async function main() {
  const username = process.argv[2]?.trim().toLowerCase();
  const password = process.argv[3];
  if (!username || !password) {
    throw new Error("Usage: pnpm auth:check-password <username> <password>");
  }

  const user = await db.query.users.findFirst({
    where: eq(users.username, username),
  });
  if (!user) {
    console.log(`Unknown username: ${username}`);
    process.exit(1);
  }
  if (!user.passwordHash) {
    console.log(`User ${username} has no password hash`);
    process.exit(1);
  }

  const valid = await verifyPassword(password, user.passwordHash);
  console.log(valid ? "Password matches" : "Password mismatch");
  process.exit(valid ? 0 : 1);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
