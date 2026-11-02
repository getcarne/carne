const db = require("std/db");

// Async ORM over sqlite (in-memory here; swap for "sqlite:app.db"
// or a postgres spec). Wrap in an async IIFE: top-level await is v1
// out of scope, so the run drains the completion promise instead.
(async () => {
const s = await db.connect("sqlite::memory:");

// Schema first: models declare tables, migrate() tracks versions.
const User = s.defineModel("User", {table: "users", columns: {
  id: {type: "integer", primaryKey: true, autoIncrement: true},
  name: {type: "text", notNull: true},
  age: {type: "integer", default: 0}}});
const Post = s.defineModel("Post", {table: "posts", columns: {
  id: {type: "integer", primaryKey: true, autoIncrement: true},
  user_id: {type: "integer"},
  title: {type: "text"}}});
await User.createTable();
await Post.createTable();
User.hasMany(Post);
Post.belongsTo(User);

// Builder: parameterized (? here, $1..$n on postgres), never
// interpolated. Terminals are async; Sync twins exist for scripts.
await s.table("users").insert([
  {name: "ana", age: 30},
  {name: "bo", age: 17},
  {name: "cy", age: 25}]).run();
const adults = await s.table("users").where({age: {gte: 18}})
  .orderBy("age", "desc").select(["name", "age"]).all();
console.log("adults: " + adults.map(u => u.name).join(", "));

// Models: instances with save()/remove(), relations as getters.
const ana = await User.where({name: "ana"}).first();
await Post.create({user_id: ana.id, title: "hello db"});
console.log("ana's posts: " + (await ana.getPosts()).length);
ana.age = 31;
await ana.save();

// Transactions roll back on throw (nesting uses savepoints).
try {
  await s.transaction(async (tx) => {
    await tx.table("users").insert({name: "ghost"}).run();
    throw new Error("boom");
  });
} catch (e) { /* rolled back */ }
console.log("users: " + (await User.all()).length);

// Raw escape hatch: validated SQL with bound params, same as ever.
const n = await s.query("SELECT COUNT(*) AS c FROM users WHERE age > ?",
  [18]);
console.log("over 18: " + n.rows[0].c);

await s.close();
})();
