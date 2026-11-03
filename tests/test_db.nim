from std/os import `/`, copyFile, createDir, dirExists, fileExists,
  getTempDir, parentDir, pcDir, removeDir, removeFile, walkDir
import unittest

import carne
import carne/modules
import carne/pkg/stdsync
from carne/std/db import installDriver
## Both std/os (above) and carne/std/db bind short names: never
## qualify with bare `os`/`db` in this file, use imports unqualified.

registerStd("std/db/driver", installDriver)

let stdHome = getTempDir() / "carne_std_db"
removeDir(stdHome)
createDir(stdJsStore(stdHome))
copyFile(currentSourcePath.parentDir() / ".." / "src" / "carne" /
  "std" / "js" / "db.js", stdJsStore(stdHome) / "db.js")
initStdDispatcher(stdHome)

proc tmpPath(name: string): string =
  getTempDir() / ("carne_test_db_" & name)

const syncPre = """(() => {
const d = require('std/db/driver');
const c = d.connectSync('sqlite::memory:');
c.execSync('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)');
"""

test "db driver sync crud roundtrip":
  check runCode(syncPre &
    "c.execSync(\"INSERT INTO users (name, age) VALUES (?, ?)\", " &
    "['ana', 30]); " &
    "const r = c.querySync('SELECT id, name, age FROM users'); " &
    "c.close(); " &
    "return JSON.stringify(r.rows); })()") ==
    """[{"id":1,"name":"ana","age":30}]"""

test "db driver reports rowCount changes lastInsertRowId":
  check runCode(syncPre &
    "const a = c.execSync(\"INSERT INTO users (name) VALUES ('x')\"); " &
    "const b = c.querySync('SELECT * FROM users'); " &
    "c.close(); " &
    "return b.rowCount + ':' + a.changes + ':' + a.lastInsertRowId; })()") ==
    "1:1:1"

test "db driver null int float bool text mapping":
  check runCode(
    "(() => { const d = require('std/db/driver'); " &
    "const c = d.connectSync('sqlite::memory:'); " &
    "c.execSync('CREATE TABLE t (a, b, c, e, f)'); " &
    "c.execSync('INSERT INTO t VALUES (?, ?, ?, ?, ?)', " &
    "[null, 42, 1.5, true, 'hi']); " &
    "const r = c.querySync('SELECT a, b, c, e, f FROM t'); " &
    "c.close(); " &
    "return JSON.stringify(r.rows[0]); })()") ==
    """{"a":null,"b":42,"c":1.5,"e":1,"f":"hi"}"""

test "db driver blob roundtrip is a Uint8Array":
  check runCode(
    "(() => { const d = require('std/db/driver'); " &
    "const c = d.connectSync('sqlite::memory:'); " &
    "c.execSync('CREATE TABLE t (data BLOB)'); " &
    "c.execSync(\"INSERT INTO t VALUES (x'0001ff')\"); " &
    "const r = c.querySync('SELECT data FROM t'); " &
    "const b = r.rows[0].data; " &
    "c.close(); " &
    "return (b instanceof Uint8Array) + ':' + b.length + ':' + " &
    "b[0] + ',' + b[1] + ',' + b[2]; })()") == "true:3:0,1,255"

test "db driver placeholders bind values not code":
  check runCode(syncPre &
    "c.execSync('INSERT INTO users (name) VALUES (?)', " &
    "[\"x'); DROP TABLE users; --\"]); " &
    "const r = c.querySync('SELECT COUNT(*) AS n FROM users'); " &
    "c.close(); " &
    "return r.rows[0].n; })()") == "1"

test "db driver missing table throws":
  expect CarneError:
    discard runCode(
      "require('std/db/driver').connectSync('sqlite::memory:')" &
      ".querySync('SELECT * FROM nope')")

test "db driver invalid sql throws before executing":
  expect CarneError:
    discard runCode(
      "require('std/db/driver').connectSync('sqlite::memory:')" &
      ".querySync('SELECT FROM WHERE')")

test "db driver postgres placeholders rejected on sqlite":
  expect CarneError:
    discard runCode(
      "require('std/db/driver').connectSync('sqlite::memory:')" &
      ".querySync('SELECT $1', [1])")

test "db driver param count mismatch throws":
  expect CarneError:
    discard runCode(syncPre &
      "c.querySync('SELECT * FROM users WHERE id = ? AND age = ?', [1]);")

test "db driver bad spec throws with usage":
  expect CarneError:
    discard runCode("require('std/db/driver').connectSync('mysql://x')")
  expect CarneError:
    discard runCode(
      "require('std/db/driver').connectSync({dialect: 'sqlite'})")
  expect CarneError:
    discard runCode("require('std/db/driver').connectSync(42)")

test "db driver close is idempotent, use after close throws":
  check runCode(
    "(() => { const d = require('std/db/driver'); " &
    "const c = d.connectSync('sqlite::memory:'); " &
    "c.close(); c.close(); return 'ok'; })()") == "ok"
  expect CarneError:
    discard runCode(
      "(() => { const d = require('std/db/driver'); " &
      "const c = d.connectSync('sqlite::memory:'); " &
      "c.close(); c.querySync('SELECT 1');")

test "db driver exposes dialect":
  check runCode(
    "require('std/db/driver').connectSync('sqlite::memory:').dialect") ==
    "sqlite"

test "db driver file-backed database persists":
  let p = tmpPath("persist.db")
  defer: removeFile(p)
  check runCode(
    "(() => { const d = require('std/db/driver'); " &
    "const c = d.connectSync('sqlite:" & p & "'); " &
    "c.execSync('CREATE TABLE t (a TEXT)'); " &
    "c.execSync(\"INSERT INTO t VALUES ('kept')\"); " &
    "c.close(); return 'wrote'; })()") == "wrote"
  check fileExists(p)
  check runCode(
    "(() => { const d = require('std/db/driver'); " &
    "const c = d.connectSync('sqlite:" & p & "'); " &
    "const r = c.querySync('SELECT a FROM t'); " &
    "c.close(); return r.rows[0].a; })()") == "kept"

test "db driver async connect query close":
  check runCode("(async () => { " &
    "const d = require('std/db/driver'); " &
    "const c = await d.connect('sqlite::memory:'); " &
    "await c.exec('CREATE TABLE t (a INTEGER)'); " &
    "await c.exec('INSERT INTO t VALUES (?)', [7]); " &
    "const r = await c.query('SELECT a FROM t'); " &
    "await c.close(); " &
    "return r.rows[0].a + ':' + r.rowCount; })()") == "7:1"

test "db driver async errors reject":
  expect CarneError:
    discard runCode("(async () => { " &
      "const d = require('std/db/driver'); " &
      "const c = await d.connect('sqlite::memory:'); " &
      "await c.query('SELECT * FROM nope'); })()")
  expect CarneError:
    discard runCode("(async () => { " &
      "await require('std/db/driver').connect('bogus'); })()")

test "db driver missing file error":
  expect CarneError:
    discard runCode(
      "require('std/db/driver')" &
      ".connectSync('sqlite:/no/such/dir/carne_xyz.db')")

const ormPre = """(async () => {
const db = require('std/db');
const s = await db.connect('sqlite::memory:');
await s.exec('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, age INTEGER)');
await s.table('users').insert([{name: 'ana', age: 30}, {name: 'bo', age: 17}, {name: 'cy', age: 25}]).run();
"""

test "db orm builder insert select first":
  check runCode(ormPre &
    "const rows = await s.table('users').select(['name']).all(); " &
    "const one = await s.table('users').where({name: 'bo'}).first(); " &
    "const miss = await s.table('users').where({name: 'zz'}).first(); " &
    "await s.close(); " &
    "return rows.length + ':' + rows[0].name + ':' + one.age + ':' + miss; " &
    "})()") == "3:ana:17:null"

test "db orm where operators":
  check runCode(ormPre &
    "const a = await s.table('users').where({age: {gte: 18}}).all(); " &
    "const b = await s.table('users').where({name: {in: ['ana', 'cy']}}).all(); " &
    "const c = await s.table('users').where({age: {lt: 20}}).all(); " &
    "const d = await s.table('users').where({age: {ne: 30}}).all(); " &
    "const e = await s.table('users').where('age > ? AND name LIKE ?', [20, '%y']).all(); " &
    "await s.close(); " &
    "return a.length + ':' + b.length + ':' + c.length + ':' + " &
    "d.length + ':' + e.length + ':' + e[0].name; " &
    "})()") == "2:2:1:2:1:cy"

test "db orm null conditions":
  check runCode("(async () => { " &
    "const db = require('std/db'); " &
    "const s = await db.connect('sqlite::memory:'); " &
    "await s.exec('CREATE TABLE t (a TEXT, b INTEGER)'); " &
    "await s.table('t').insert([{a: null, b: 1}, {a: 'x', b: null}]).run(); " &
    "const n = await s.table('t').where({a: null}).all(); " &
    "const m = await s.table('t').where({b: {ne: null}}).all(); " &
    "await s.close(); " &
    "return n.length + ':' + n[0].b + ':' + m.length; " &
    "})()") == "1:1:1"

test "db orm order limit offset":
  check runCode(ormPre &
    "const rows = await s.table('users').orderBy('age', 'desc')" &
    ".limit(2).offset(1).all(); " &
    "await s.close(); " &
    "return rows.map(r => r.name).join(','); " &
    "})()") == "cy,bo"

test "db orm update and delete":
  check runCode(ormPre &
    "await s.table('users').where({name: 'bo'}).update({age: 18}).run(); " &
    "const u = await s.table('users').where({name: 'bo'}).first(); " &
    "await s.table('users').where({age: {lt: 20}}).delete().run(); " &
    "const left = await s.table('users').all(); " &
    "await s.close(); " &
    "return u.age + ':' + left.length; " &
    "})()") == "18:2"

test "db orm delete without where throws":
  expect CarneError:
    discard runCode(ormPre &
      "await s.table('users').delete().run(); })()")

test "db orm builder errors":
  expect CarneError:
    discard runCode(ormPre &
      "await s.table('users').where({age: {bogus: 1}}).all(); })()")
  expect CarneError:
    discard runCode(ormPre &
      "await s.table('users').insert([]).run(); })()")
  expect CarneError:
    discard runCode(ormPre &
      "await s.table('users').run(); })()")
  expect CarneError:
    discard runCode(ormPre &
      "await s.table('users').where({age: undefined}).all(); })()")

test "db orm raw query and exec passthrough":
  check runCode(ormPre &
    "const r = await s.query('SELECT COUNT(*) AS n FROM users WHERE age > ?', [18]); " &
    "await s.exec(\"UPDATE users SET age = age + 1 WHERE name = 'ana'\"); " &
    "const a = await s.querySync('SELECT age FROM users WHERE name = \\'ana\\''); " &
    "await s.close(); " &
    "return r.rows[0].n + ':' + a.rows[0].age; " &
    "})()") == "2:31"

test "db orm invalid sql rejects through builder":
  expect CarneError:
    discard runCode(ormPre &
      "await s.exec('CREATE TABLE'); })()")

test "db orm model crud":
  check runCode("(async () => { " &
    "const db = require('std/db'); " &
    "const s = await db.connect('sqlite::memory:'); " &
    "const User = s.defineModel('User', {table: 'users', columns: {" &
    "id: {type: 'integer', primaryKey: true, autoIncrement: true}, " &
    "name: {type: 'text', notNull: true}, " &
    "age: {type: 'integer', default: 0}}}); " &
    "await User.createTable(); " &
    "const a = await User.create({name: 'ana', age: 30}); " &
    "await User.create({name: 'bo'}); " &
    "const f = await User.find(a.id); " &
    "f.age = 31; await f.save(); " &
    "const g = await User.find(a.id); " &
    "await (await User.find(2)).remove(); " &
    "const all = await User.all(); " &
    "await s.close(); " &
    "return a.id + ':' + f.name + ':' + g.age + ':' + all.length; " &
    "})()") == "1:ana:31:1"

test "db orm model validation errors":
  expect CarneError:
    discard runCode("(async () => { " &
      "const db = require('std/db'); " &
      "const s = await db.connect('sqlite::memory:'); " &
      "s.defineModel('NoPk', {columns: {a: {type: 'text'}}}); })()")
  expect CarneError:
    discard runCode("(async () => { " &
      "const db = require('std/db'); " &
      "const s = await db.connect('sqlite::memory:'); " &
      "s.defineModel('Bad', {columns: {a: {type: 'fancy'}}}); " &
      "await s.close(); })()")

test "db orm relations":
  check runCode("(async () => { " &
    "const db = require('std/db'); " &
    "const s = await db.connect('sqlite::memory:'); " &
    "const User = s.defineModel('User', {table: 'users', columns: {" &
    "id: {type: 'integer', primaryKey: true, autoIncrement: true}, " &
    "name: {type: 'text'}}}); " &
    "const Post = s.defineModel('Post', {table: 'posts', columns: {" &
    "id: {type: 'integer', primaryKey: true, autoIncrement: true}, " &
    "user_id: {type: 'integer'}, title: {type: 'text'}}}); " &
    "await User.createTable(); await Post.createTable(); " &
    "User.hasMany(Post); Post.belongsTo(User); " &
    "const u = await User.create({name: 'ana'}); " &
    "await Post.create({user_id: u.id, title: 'one'}); " &
    "await Post.create({user_id: u.id, title: 'two'}); " &
    "const posts = await u.getPosts(); " &
    "const owner = await posts[0].getUser(); " &
    "await s.close(); " &
    "return posts.length + ':' + posts[0].title + ':' + owner.name; " &
    "})()") == "2:one:ana"

test "db orm transaction commit and rollback":
  check runCode("(async () => { " &
    "const db = require('std/db'); " &
    "const s = await db.connect('sqlite::memory:'); " &
    "await s.exec('CREATE TABLE t (a TEXT)'); " &
    "await s.transaction(async (tx) => { " &
    "await tx.table('t').insert({a: 'kept'}).run(); }); " &
    "try { await s.transaction(async (tx) => { " &
    "await tx.table('t').insert({a: 'lost'}).run(); " &
    "throw new Error('boom'); }); } catch (e) {} " &
    "const r = await s.table('t').all(); " &
    "await s.close(); " &
    "return r.length + ':' + r[0].a; " &
    "})()") == "1:kept"

test "db orm nested transaction uses savepoints":
  check runCode("(async () => { " &
    "const db = require('std/db'); " &
    "const s = await db.connect('sqlite::memory:'); " &
    "await s.exec('CREATE TABLE t (a TEXT)'); " &
    "await s.transaction(async (tx) => { " &
    "await tx.table('t').insert({a: 'outer'}).run(); " &
    "try { await tx.transaction(async (inner) => { " &
    "await inner.table('t').insert({a: 'inner'}).run(); " &
    "throw new Error('inner boom'); }); } catch (e) {} }); " &
    "const r = await s.table('t').all(); " &
    "await s.close(); " &
    "return r.length + ':' + r[0].a; " &
    "})()") == "1:outer"

test "db orm migrate applies once":
  check runCode("(async () => { " &
    "const db = require('std/db'); " &
    "const s = await db.connect('sqlite::memory:'); " &
    "const migs = [{version: 1, up: 'CREATE TABLE t (a TEXT)'}, " &
    "{version: 2, up: [\"INSERT INTO t VALUES ('x')\", " &
    "\"INSERT INTO t VALUES ('y')\"]}]; " &
    "const first = await s.migrate(migs); " &
    "const second = await s.migrate(migs); " &
    "const n = await s.query('SELECT COUNT(*) AS c FROM t'); " &
    "await s.close(); " &
    "return first.join(',') + ':' + second.length + ':' + n.rows[0].c; " &
    "})()") == "1,2:0:2"

test "db orm sync connect and terminals":
  check runCode("(() => { " &
    "const db = require('std/db'); " &
    "const s = db.connectSync('sqlite::memory:'); " &
    "s.execSync('CREATE TABLE t (a INTEGER)'); " &
    "s.table('t').insert({a: 5}).runSync(); " &
    "const rows = s.table('t').allSync(); " &
    "const one = s.table('t').firstSync(); " &
    "const applied = s.migrateSync([{version: 1, " &
    "up: 'CREATE TABLE m (v INTEGER)'}]); " &
    "s.close(); " &
    "return rows.length + ':' + one.a + ':' + applied.join(','); " &
    "})()") == "1:5:1"
