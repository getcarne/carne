const sql = require("std/sql");

// Same query, three dialects: the AST shape is identical.
const query = "SELECT name, age FROM users WHERE age >= 18 ORDER BY name LIMIT 10;";
for (const d of ["sqlite", "postgres", "mysql"]) {
  const ast = sql[d].parse(query);
  const select = ast.children[0];
  const from = select.children[1];
  console.log(d + ": " + ast.kind + " > " + select.kind +
    " on " + from.children[0].children[0].value);
}

// Placeholders are per-driver: $n is postgres, :name/@name/? is sqlite.
console.log("pg $1: " + sql.postgres.validate("SELECT * FROM t WHERE id = $1").valid);
console.log("lite $1: " + JSON.stringify(sql.sqlite.validate("SELECT * FROM t WHERE id = $1")));
console.log("lite :name: " + sql.sqlite.validate("SELECT * FROM t WHERE id = :name").valid);

// Quoting is per-driver too: backticks are mysql, "ident" is postgres/sqlite.
console.log("mysql backticks: " + sql.mysql.validate("SELECT `name` FROM `users`").valid);
console.log("pg backticks: " + sql.postgres.validate("SELECT `name` FROM t").valid);

// SQLite-only statements fail elsewhere, with the reason attached.
const pragma = sql.postgres.validate("PRAGMA journal_mode;");
console.log("pg pragma valid: " + pragma.valid);
console.log("reason: " + pragma.error.split("\n").pop());

// DDL roundtrip through the AST: table name and columns are navigation away.
const ddl = sql.sqlite.parse(
  "CREATE TABLE IF NOT EXISTS users(id INTEGER PRIMARY KEY, name TEXT NOT NULL);");
const table = ddl.children[0];
console.log("ddl: " + table.kind + " " + table.children[0].value +
  " (" + (table.children.length - 1) + " columns)");
console.log("first column: " +
  table.children[1].children[0].value + " " + table.children[1].children[1].value);

// AST back to SQL, plus normalized formatting.
const ast = sql.sqlite.parse("select a from t where a = 1");
console.log("stringify: " + sql.sqlite.stringify(ast));
console.log("format: " + sql.sqlite.format("select a from t where a = 1"));
console.log("format upper: " +
  sql.sqlite.format("select a from t", {upperCase: true}));
