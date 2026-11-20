import "dotenv/config";
import readline from "node:readline";
import { stdin, stdout } from "node:process";
import { eq } from "drizzle-orm";
import { db } from "../src/db";
import { users } from "../src/db/schema";
import { hashPassword } from "../src/lib/password";

function question(query: string): Promise<string> {
  const rl = readline.createInterface({
    input: stdin,
    output: stdout,
    terminal: true,
  });

  return new Promise((resolve) => {
    rl.question(query, (answer) => {
      rl.close();
      resolve(answer);
    });
  });
}

async function main() {
  const username = (await question("Username: ")).trim().toLowerCase();
  const password = await question("New password (12+ characters): ");
  const confirm = await question("Confirm password: ");

  if (!/^[a-z0-9_-]{3,32}$/.test(username)) {
    throw new Error("Invalid username.");
  }
  if (password.length < 12) {
    throw new Error("Password must be at least 12 characters.");
  }
  if (password !== confirm) {
    throw new Error("Passwords do not match.");
  }

  const passwordHash = await hashPassword(password);
  const [row] = await db
    .update(users)
    .set({ passwordHash })
    .where(eq(users.username, username))
    .returning({ id: users.id });

  if (!row) {
    throw new Error(`Username not found: ${username}`);
  }

  console.log(`Password updated for ${username}.`);
  process.exit(0);
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
