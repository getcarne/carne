// Carne std/db: async ORM over the std/db/driver executor.
//
//   const db = require("std/db");
//   const sqlite = await db.connect("sqlite::memory:");
//   await sqlite.exec("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)");
//   await sqlite.table("users").insert({name: "ana"}).run();
//   const rows = await sqlite.table("users").where({name: "ana"}).all();
//   const User = sqlite.defineModel("User", {columns: {
//     id: {type: "integer", primaryKey: true, autoIncrement: true},
//     name: {type: "text", notNull: true}}});
//   await User.create({name: "ana"});
//
// The builder generates parameterized SQL only (? for sqlite, $1..$n
// for postgres); values bind separately and are never interpolated.
// Identifiers are double-quoted per dialect. Every statement is
// validated by the driver's std/sql grammars before it executes.
// Terminals are async (all/first/run); Sync twins (allSync/firstSync/
// runSync) and the raw handle (db.raw) cover blocking scripts and
// boot-time migrations. Models are async-only in v1.
"use strict";
/*
 * @typedef {object} ColumnDef - Model column definition.
 * @typedef {object} QueryResult - Driver result ({rows, rowCount, changes}).
 */

var driver = require("std/db/driver");

/*
 * Requires at least `min` arguments.
 * @param {string} fname - Function name for errors.
 * @param {number} given - arguments.length at the call site.
 * @param {number} min - Minimum accepted arity.
 * @returns {void} Throws on too few arguments.
 */
function arity(fname, given, min) {
  if (given < min) {
    throw new Error(fname + ": expected at least " + min +
      " argument(s), got " + given);
  }
}

/*
 * JS typeof name for type-mismatch errors (null/array distinguished).
 * @param {any} v - Value to classify.
 * @returns {string} The JS type name.
 */
function jsKind(v) {
  if (v === null) return "null";
  if (Array.isArray(v)) return "array";
  return typeof v;
}

/*
 * Requires a string argument.
 * @param {string} fname - Function name for errors.
 * @param {string} pname - Parameter name for errors.
 * @param {any} v - The value to check.
 * @returns {string} The value, narrowed to string.
 */
function reqStr(fname, pname, v) {
  if (typeof v !== "string") {
    throw new Error(fname + ": type mismatch parameter: `" + pname +
      "`. Got `" + jsKind(v) + "`, expected `string`");
  }
  return v;
}

/*
 * Requires a plain object argument (arrays rejected).
 * @param {string} fname - Function name for errors.
 * @param {string} pname - Parameter name for errors.
 * @param {any} v - The value to check.
 * @returns {object} The value, narrowed to object.
 */
function reqObj(fname, pname, v) {
  if (v === null || typeof v !== "object" || Array.isArray(v)) {
    throw new Error(fname + ": type mismatch parameter: `" + pname +
      "`. Got `" + jsKind(v) + "`, expected `object`");
  }
  return v;
}

/*
 * Double-quotes an identifier for sqlite/postgres.
 * @param {string} name - Table or column name.
 * @returns {string} The quoted identifier.
 */
function ident(name) {
  reqStr("db", "name", name);
  if (name.length === 0) {
    throw new Error("db: identifier must not be empty");
  }
  return "\"" + name.replace(/"/g, "\"\"") + "\"";
}

/*
 * Maps a JS value to a bindable param (Date -> ISO string).
 * Undefined and binary values throw with a clear message.
 * @param {string} fname - Function name for errors.
 * @param {any} v - The value to map.
 * @returns {any} The bindable value.
 */
function toParam(fname, v) {
  if (v === undefined) {
    throw new Error(fname + ": undefined is not a valid bind value" +
      " (use null for SQL NULL)");
  }
  if (v instanceof Date) {
    return v.toISOString();
  }
  if (v instanceof Uint8Array) {
    throw new Error(fname + ": blob bind params are not supported" +
      " in v1 (store bytes out of band)");
  }
  return v;
}

/*
 * Next placeholder for the dialect.
 * @param {string} dialect - sqlite or postgres.
 * @param {number} n - 1-based parameter index.
 * @returns {string} The placeholder text.
 */
function placeholder(dialect, n) {
  return dialect === "postgres" ? "$" + n : "?";
}

var whereOps = {
  eq: "=", ne: "<>", gt: ">", gte: ">=", lt: "<", lte: "<=",
  like: "LIKE", ilike: "LIKE"
};

/*
 * Compiles one where-object entry into SQL + params.
 * @param {string} dialect - sqlite or postgres.
 * @param {string} col - Column name.
 * @param {any} cond - Equality value or operator object.
 * @param {Array} params - Bound values accumulator.
 * @param {string} fname - Function name for errors.
 * @returns {string} The condition fragment.
 */
function compileCond(dialect, col, cond, params, fname) {
  var c = ident(col);
  if (cond === null) {
    return c + " IS NULL";
  }
  if (cond === undefined) {
    throw new Error(fname + ": undefined is not a valid condition for `" +
      col + "` (use null for IS NULL)");
  }
  if (typeof cond !== "object" || cond instanceof Date) {
    params.push(toParam(fname, cond));
    return c + " = " + placeholder(dialect, params.length);
  }
  var parts = [];
  var keys = Object.keys(cond);
  if (keys.length === 0) {
    throw new Error(fname + ": empty operator object for `" + col + "`");
  }
  for (var i = 0; i < keys.length; i++) {
    var op = keys[i];
    var v = cond[op];
    if (op === "in" || op === "notIn") {
      if (!Array.isArray(v) || v.length === 0) {
        throw new Error(fname + ": `" + op + "` needs a non-empty array");
      }
      if (v.length === 1) {
        params.push(toParam(fname, v[0]));
        parts.push(c + (op === "in" ? " IN (" : " NOT IN (") +
          placeholder(dialect, params.length) + ")");
        continue;
      }
      // Multi-element IN lists are beyond the std/sql grammars (they
      // accept a single element); an OR chain filters identically.
      var ors = [];
      for (var j = 0; j < v.length; j++) {
        params.push(toParam(fname, v[j]));
        ors.push(c + " = " + placeholder(dialect, params.length));
      }
      var group = "(" + ors.join(" OR ") + ")";
      parts.push(op === "in" ? group : "NOT " + group);
    } else if (op === "eq" && v === null) {
      parts.push(c + " IS NULL");
    } else if (op === "ne" && v === null) {
      parts.push(c + " IS NOT NULL");
    } else if (v === undefined) {
      throw new Error(fname + ": undefined is not a valid value for `" +
        op + "` on `" + col + "` (use null for SQL NULL)");
    } else if (Object.prototype.hasOwnProperty.call(whereOps, op)) {
      params.push(toParam(fname, v));
      parts.push(c + " " + whereOps[op] + " " +
        placeholder(dialect, params.length));
    } else {
      throw new Error(fname + ": unknown operator `" + op + "`" +
        " (eq, ne, gt, gte, lt, lte, like, ilike, in, notIn)");
    }
  }
  return parts.join(" AND ");
}

/*
 * Fluent SELECT/INSERT/UPDATE/DELETE builder over one table.
 * @param {object} db - Owning Database.
 * @param {string} table - Table name.
 * @returns {void} Chain via methods; execute via terminals.
 */
function QueryBuilder(db, table) {
  this.db = db;
  this.table = table;
  this.kind = "select";
  this.cols = ["*"];
  this.wheres = [];
  this.orders = [];
  this.limitN = null;
  this.offsetN = null;
  this.joins = [];
  this.values = null;
}

/*
 * Adds WHERE conditions (object, or raw fragment + params).
 * @param {object|string} cond - Conditions object or SQL fragment.
 * @param {Array} [params] - Bind values for a raw fragment.
 * @returns {QueryBuilder} This builder, for chaining.
 */
QueryBuilder.prototype.where = function (cond, params) {
  if (typeof cond === "string") {
    reqStr("db.table.where", "cond", cond);
    var ps = params === undefined ? [] : params;
    if (!Array.isArray(ps)) {
      throw new Error("db.table.where: type mismatch parameter: `params`." +
        " Got `" + jsKind(params) + "`, expected `array`");
    }
    this.wheres.push({raw: cond, params: ps});
    return this;
  }
  reqObj("db.table.where", "cond", cond);
  this.wheres.push({obj: cond});
  return this;
};

/*
 * Selects columns (default *).
 * @param {Array|string} cols - Column names, or "*" / single name.
 * @returns {QueryBuilder} This builder, for chaining.
 */
QueryBuilder.prototype.select = function (cols) {
  if (cols === undefined) {
    this.cols = ["*"];
    return this;
  }
  var list = Array.isArray(cols) ? cols : [cols];
  for (var i = 0; i < list.length; i++) {
    reqStr("db.table.select", "cols[" + i + "]", list[i]);
  }
  this.cols = list;
  this.kind = "select";
  return this;
};

/*
 * Adds an ORDER BY clause.
 * @param {string} col - Column name.
 * @param {string} [dir] - asc or desc (default asc).
 * @returns {QueryBuilder} This builder, for chaining.
 */
QueryBuilder.prototype.orderBy = function (col, dir) {
  reqStr("db.table.orderBy", "col", col);
  var d = dir === undefined ? "asc" : dir;
  if (d !== "asc" && d !== "desc") {
    throw new Error("db.table.orderBy: dir must be \"asc\" or \"desc\"," +
      " got \"" + d + "\"");
  }
  this.orders.push({col: col, dir: d});
  return this;
};

/*
 * Adds a LIMIT clause.
 * @param {number} n - Non-negative row cap.
 * @returns {QueryBuilder} This builder, for chaining.
 */
QueryBuilder.prototype.limit = function (n) {
  if (typeof n !== "number" || n < 0 || Math.floor(n) !== n) {
    throw new Error("db.table.limit: type mismatch parameter: `n`." +
      " Got `" + jsKind(n) + "`, expected non-negative `integer`");
  }
  this.limitN = n;
  return this;
};

/*
 * Adds an OFFSET clause.
 * @param {number} n - Non-negative row skip.
 * @returns {QueryBuilder} This builder, for chaining.
 */
QueryBuilder.prototype.offset = function (n) {
  if (typeof n !== "number" || n < 0 || Math.floor(n) !== n) {
    throw new Error("db.table.offset: type mismatch parameter: `n`." +
      " Got `" + jsKind(n) + "`, expected non-negative `integer`");
  }
  this.offsetN = n;
  return this;
};

/*
 * Adds a JOIN clause.
 * @param {string} kind - inner, left or right.
 * @param {string} table - Joined table name.
 * @param {string} on - Raw ON condition (identifiers pre-quoted by caller).
 * @returns {QueryBuilder} This builder, for chaining.
 */
QueryBuilder.prototype.join = function (kind, table, on) {
  reqStr("db.table.join", "kind", kind);
  reqStr("db.table.join", "table", table);
  reqStr("db.table.join", "on", on);
  if (kind !== "inner" && kind !== "left" && kind !== "right") {
    throw new Error("db.table.join: kind must be inner, left or right," +
      " got \"" + kind + "\"");
  }
  this.joins.push({kind: kind, table: table, on: on});
  return this;
};

/*
 * Starts an INSERT of one row or an array of rows.
 * @param {object|Array} row - Row object or array of row objects.
 * @returns {QueryBuilder} This builder; execute with run().
 */
QueryBuilder.prototype.insert = function (row) {
  var rows = Array.isArray(row) ? row : [row];
  if (rows.length === 0) {
    throw new Error("db.table.insert: needs at least one row");
  }
  for (var i = 0; i < rows.length; i++) {
    reqObj("db.table.insert", "row", rows[i]);
  }
  this.kind = "insert";
  this.values = rows;
  return this;
};

/*
 * Starts an UPDATE with the given assignments.
 * @param {object} patch - Column assignments.
 * @returns {QueryBuilder} This builder; execute with run().
 */
QueryBuilder.prototype.update = function (patch) {
  reqObj("db.table.update", "patch", patch);
  this.kind = "update";
  this.values = patch;
  return this;
};

/*
 * Starts a DELETE (refuses to run without WHERE).
 * @returns {QueryBuilder} This builder; execute with run().
 */
QueryBuilder.prototype.delete = function () {
  this.kind = "delete";
  return this;
};

/*
 * Compiles the builder to SQL + params for the dialect.
 * @param {string} dialect - sqlite or postgres.
 * @returns {object} {text, params}.
 */
QueryBuilder.prototype.toSQL = function (dialect) {
  var fname = "db.table";
  var params = [];
  var t = ident(this.table);
  var self = this;
  /*
   * Compiles stored WHERE entries in call order. Params push in text
   * order, so UPDATE builds SET first and calls this after.
   * @returns {string} The WHERE clause, or "" when unfiltered.
   */
  function whereClause() {
    if (self.wheres.length === 0) {
      return "";
    }
    var frags = [];
    for (var w = 0; w < self.wheres.length; w++) {
      var entry = self.wheres[w];
      if (entry.raw !== undefined) {
        for (var q = 0; q < entry.params.length; q++) {
          params.push(toParam(fname, entry.params[q]));
        }
        frags.push("(" + entry.raw + ")");
      } else {
        var keys = Object.keys(entry.obj);
        for (var k = 0; k < keys.length; k++) {
          frags.push(compileCond(dialect, keys[k], entry.obj[keys[k]],
            params, fname));
        }
      }
    }
    return " WHERE " + frags.join(" AND ");
  }
  if (this.kind === "insert") {
    var cols = Object.keys(this.values[0]);
    if (cols.length === 0) {
      throw new Error(fname + ".insert: row must not be empty");
    }
    var colSql = [];
    for (var c = 0; c < cols.length; c++) {
      colSql.push(ident(cols[c]));
    }
    var rowGroups = [];
    for (var r = 0; r < this.values.length; r++) {
      var holders = [];
      for (var h = 0; h < cols.length; h++) {
        if (!Object.prototype.hasOwnProperty.call(this.values[r],
            cols[h])) {
          throw new Error(fname + ".insert: row " + r + " misses `" +
            cols[h] + "`");
        }
        params.push(toParam(fname, this.values[r][cols[h]]));
        holders.push(placeholder(dialect, params.length));
      }
      rowGroups.push("(" + holders.join(", ") + ")");
    }
    return {
      text: "INSERT INTO " + t + " (" + colSql.join(", ") + ") VALUES " +
        rowGroups.join(", "),
      params: params
    };
  }
  if (this.kind === "update") {
    var setKeys = Object.keys(this.values);
    if (setKeys.length === 0) {
      throw new Error(fname + ".update: patch must not be empty");
    }
    var sets = [];
    for (var s = 0; s < setKeys.length; s++) {
      params.push(toParam(fname, this.values[setKeys[s]]));
      sets.push(ident(setKeys[s]) + " = " +
        placeholder(dialect, params.length));
    }
    return {
      text: "UPDATE " + t + " SET " + sets.join(", ") + whereClause(),
      params: params
    };
  }
  if (this.kind === "delete") {
    var delWhere = whereClause();
    if (delWhere === "") {
      throw new Error(fname + ".delete: refusing to delete without WHERE" +
        " (use a raw exec for full-table deletes)");
    }
    return {text: "DELETE FROM " + t + delWhere, params: params};
  }
  var sel = "*";
  if (!(this.cols.length === 1 && this.cols[0] === "*")) {
    var parts = [];
    for (var m = 0; m < this.cols.length; m++) {
      parts.push(ident(this.cols[m]));
    }
    sel = parts.join(", ");
  }
  var sql = "SELECT " + sel + " FROM " + t;
  for (var j = 0; j < this.joins.length; j++) {
    var jn = this.joins[j];
    sql += " " + jn.kind.toUpperCase() + " JOIN " + ident(jn.table) +
      " ON " + jn.on;
  }
  sql += whereClause();
  if (this.orders.length > 0) {
    var ords = [];
    for (var o = 0; o < this.orders.length; o++) {
      ords.push(ident(this.orders[o].col) + " " +
        this.orders[o].dir.toUpperCase());
    }
    sql += " ORDER BY " + ords.join(", ");
  }
  if (this.limitN !== null) {
    sql += " LIMIT " + this.limitN;
  }
  if (this.offsetN !== null) {
    sql += " OFFSET " + this.offsetN;
  }
  return {text: sql, params: params};
};

/*
 * Runs the SELECT, returning all rows.
 * @returns {Promise<Array>} The result rows.
 */
QueryBuilder.prototype.all = function () {
  var q = this.toSQL(this.db.dialect);
  return this.db.query(q.text, q.params).then(function (r) {
    return r.rows;
  });
};

/*
 * Runs the SELECT, returning the first row or null.
 * @returns {Promise<object|null>} The first row, or null when empty.
 */
QueryBuilder.prototype.first = function () {
  return this.limit(1).all().then(function (rows) {
    return rows.length > 0 ? rows[0] : null;
  });
};

/*
 * Runs an INSERT/UPDATE/DELETE, returning the driver result.
 * @returns {Promise<object>} {rowCount, changes, lastInsertRowId?}.
 */
QueryBuilder.prototype.run = function () {
  if (this.kind === "select") {
    throw new Error("db.table.run: no write staged" +
      " (insert/update/delete first, or use all() for reads)");
  }
  var q = this.toSQL(this.db.dialect);
  return this.db.exec(q.text, q.params);
};

/*
 * Blocking all(): same SELECT over querySync.
 * @returns {Array} The result rows.
 */
QueryBuilder.prototype.allSync = function () {
  var q = this.toSQL(this.db.dialect);
  return this.db.querySync(q.text, q.params).rows;
};

/*
 * Blocking first(): same SELECT over querySync.
 * @returns {object|null} The first row, or null when empty.
 */
QueryBuilder.prototype.firstSync = function () {
  var rows = this.limit(1).allSync();
  return rows.length > 0 ? rows[0] : null;
};

/*
 * Blocking run(): same write over execSync.
 * @returns {object} {rowCount, changes, lastInsertRowId?}.
 */
QueryBuilder.prototype.runSync = function () {
  if (this.kind === "select") {
    throw new Error("db.table.runSync: no write staged" +
      " (insert/update/delete first, or use allSync() for reads)");
  }
  var q = this.toSQL(this.db.dialect);
  return this.db.execSync(q.text, q.params);
};

/*
 * DDL fragment for one column definition.
 * @param {string} dialect - sqlite or postgres.
 * @param {string} name - Column name.
 * @param {object} def - ColumnDef ({type, primaryKey?, autoIncrement?,
 * notNull?, unique?, default?}).
 * @returns {string} The column DDL fragment.
 */
function columnDDL(dialect, name, def) {
  reqObj("db.defineModel", "columns." + name, def);
  var type = def.type;
  if (type !== "integer" && type !== "real" && type !== "text" &&
      type !== "blob" && type !== "boolean" && type !== "datetime") {
    throw new Error("db.defineModel: unknown type `" + type + "` for `" +
      name + "` (integer, real, text, blob, boolean, datetime)");
  }
  var sqlType = type.toUpperCase();
  if (type === "boolean") {
    sqlType = dialect === "postgres" ? "BOOLEAN" : "INTEGER";
  } else if (type === "datetime") {
    sqlType = dialect === "postgres" ? "TIMESTAMPTZ" : "TEXT";
  } else if (type === "integer") {
    sqlType = "INTEGER";
  } else if (type === "real") {
    sqlType = dialect === "postgres" ? "DOUBLE PRECISION" : "REAL";
  } else if (type === "text") {
    sqlType = "TEXT";
  } else if (type === "blob") {
    sqlType = dialect === "postgres" ? "BYTEA" : "BLOB";
  }
  if (def.autoIncrement) {
    if (dialect === "postgres") {
      return ident(name) + " SERIAL PRIMARY KEY";
    }
    // Plain INTEGER PRIMARY KEY already auto-assigns rowids; the
    // AUTOINCREMENT keyword is beyond the std/sql grammar.
    return ident(name) + " INTEGER PRIMARY KEY";
  }
  var frag = ident(name) + " " + sqlType;
  if (def.primaryKey) {
    frag += " PRIMARY KEY";
  }
  if (def.notNull) {
    frag += " NOT NULL";
  }
  if (def.unique) {
    frag += " UNIQUE";
  }
  if (def.default !== undefined) {
    var dv = def.default;
    if (dv === null) {
      frag += " DEFAULT NULL";
    } else if (typeof dv === "number") {
      frag += " DEFAULT " + dv;
    } else if (typeof dv === "boolean") {
      frag += dialect === "postgres" ?
        " DEFAULT " + (dv ? "TRUE" : "FALSE") :
        " DEFAULT " + (dv ? "1" : "0");
    } else if (typeof dv === "string") {
      frag += " DEFAULT '" + dv.replace(/'/g, "''") + "'";
    } else {
      throw new Error("db.defineModel: bad default for `" + name + "`");
    }
  }
  return frag;
}

/*
 * Naive singularizer for FK conventions (users -> user_id).
 * @param {string} table - Table name.
 * @returns {string} The stem used for foreign keys.
 */
function singular(table) {
  if (table.length > 1 && table.charAt(table.length - 1) === "s") {
    return table.slice(0, -1);
  }
  return table;
}

/*
 * Live database: a driver handle plus builder/model/migration APIs.
 * @param {object} handle - Driver connection handle.
 * @returns {void} Use connect()/connectSync() to create.
 */
function Database(handle) {
  this.raw = handle;
  this.dialect = handle.dialect;
  this.txDepth = 0;
}

/*
 * Raw parameterized query (async).
 * @param {string} text - SQL with ? / $N placeholders.
 * @param {Array} [params] - Bind values.
 * @returns {Promise<object>} {rows, rowCount, changes, lastInsertRowId?}.
 */
Database.prototype.query = function (text, params) {
  return this.raw.query(text, params);
};

/*
 * Raw parameterized exec (async, same shape as query).
 * @param {string} text - SQL with ? / $N placeholders.
 * @param {Array} [params] - Bind values.
 * @returns {Promise<object>} {rows, rowCount, changes, lastInsertRowId?}.
 */
Database.prototype.exec = function (text, params) {
  return this.raw.exec(text, params);
};

/*
 * Blocking query over querySync.
 * @param {string} text - SQL with ? / $N placeholders.
 * @param {Array} [params] - Bind values.
 * @returns {object} {rows, rowCount, changes, lastInsertRowId?}.
 */
Database.prototype.querySync = function (text, params) {
  if (params === undefined) {
    return this.raw.querySync(text);
  }
  return this.raw.querySync(text, params);
};

/*
 * Blocking exec over execSync.
 * @param {string} text - SQL with ? / $N placeholders.
 * @param {Array} [params] - Bind values.
 * @returns {object} {rows, rowCount, changes, lastInsertRowId?}.
 */
Database.prototype.execSync = function (text, params) {
  if (params === undefined) {
    return this.raw.execSync(text);
  }
  return this.raw.execSync(text, params);
};

/*
 * Starts a fluent builder over a table.
 * @param {string} table - Table name.
 * @returns {QueryBuilder} The chained builder.
 */
Database.prototype.table = function (table) {
  reqStr("db.table", "table", table);
  return new QueryBuilder(this, table);
};

/*
 * Closes the connection (idempotent).
 * @returns {Promise<boolean>|boolean} Close result.
 */
Database.prototype.close = function () {
  return this.raw.close();
};

/*
 * Runs fn inside a transaction (nested calls use savepoints).
 * @param {Function} fn - Async function receiving the tx Database.
 * @returns {Promise<any>} fn's return value.
 */
Database.prototype.transaction = function (fn) {
  if (typeof fn !== "function") {
    throw new Error("db.transaction: type mismatch parameter: `fn`." +
      " Got `" + jsKind(fn) + "`, expected `function`");
  }
  var self = this;
  var nested = self.txDepth > 0;
  var sp = "carne_sp_" + self.txDepth;
  self.txDepth++;
  function begin() {
    if (nested) {
      return self.exec("SAVEPOINT " + sp);
    }
    return self.exec("BEGIN");
  }
  return begin().then(function () {
    return fn(self);
  }).then(function (out) {
    if (nested) {
      return self.exec("RELEASE SAVEPOINT " + sp).then(function () {
        self.txDepth--;
        return out;
      });
    }
    return self.exec("COMMIT").then(function () {
      self.txDepth--;
      return out;
    });
  }, function (err) {
    function rollback() {
      if (nested) {
        return self.exec("ROLLBACK TO SAVEPOINT " + sp).then(function () {
          return self.exec("RELEASE SAVEPOINT " + sp);
        });
      }
      return self.exec("ROLLBACK");
    }
    return rollback().then(function () {
      self.txDepth--;
      throw err;
    }, function () {
      self.txDepth--;
      throw err;
    });
  });
};

/*
 * Applies pending migrations in version order.
 * @param {Array} migrations - [{version, up}] (up: string or string[]).
 * @returns {Promise<Array>} Applied versions.
 */
Database.prototype.migrate = function (migrations) {
  if (!Array.isArray(migrations)) {
    throw new Error("db.migrate: type mismatch parameter: `migrations`." +
      " Got `" + jsKind(migrations) + "`, expected `array`");
  }
  var self = this;
  return self.exec("CREATE TABLE IF NOT EXISTS _carne_migrations" +
    " (version INTEGER PRIMARY KEY)").then(function () {
    return self.query("SELECT version FROM _carne_migrations");
  }).then(function (r) {
    var done = {};
    for (var i = 0; i < r.rows.length; i++) {
      done[r.rows[i].version] = true;
    }
    var ordered = migrations.slice().sort(function (a, b) {
      return a.version - b.version;
    });
    var chain = Promise.resolve([]);
    ordered.forEach(function (m) {
      chain = chain.then(function (applied) {
        if (typeof m.version !== "number" || m.version < 1 ||
            Math.floor(m.version) !== m.version) {
          throw new Error("db.migrate: bad version `" + m.version + "`");
        }
        if (done[m.version]) {
          return applied;
        }
        var steps = Array.isArray(m.up) ? m.up : [m.up];
        var run = Promise.resolve();
        steps.forEach(function (sql) {
          run = run.then(function () {
            return self.exec(sql);
          });
        });
        return run.then(function () {
          return self.exec("INSERT INTO _carne_migrations (version)" +
            " VALUES (" + (self.dialect === "postgres" ? "$1" : "?") +
            ")", [m.version]);
        }).then(function () {
          applied.push(m.version);
          return applied;
        });
      });
    });
    return chain;
  });
};

/*
 * Blocking migrate() over execSync/querySync (for boot scripts).
 * @param {Array} migrations - [{version, up}] (up: string or string[]).
 * @returns {Array} Applied versions.
 */
Database.prototype.migrateSync = function (migrations) {
  if (!Array.isArray(migrations)) {
    throw new Error("db.migrateSync: type mismatch parameter:" +
      " `migrations`. Got `" + jsKind(migrations) + "`, expected `array`");
  }
  var self = this;
  self.execSync("CREATE TABLE IF NOT EXISTS _carne_migrations" +
    " (version INTEGER PRIMARY KEY)");
  var r = self.querySync("SELECT version FROM _carne_migrations");
  var done = {};
  for (var i = 0; i < r.rows.length; i++) {
    done[r.rows[i].version] = true;
  }
  var ordered = migrations.slice().sort(function (a, b) {
    return a.version - b.version;
  });
  var applied = [];
  for (var m = 0; m < ordered.length; m++) {
    var item = ordered[m];
    if (typeof item.version !== "number" || item.version < 1 ||
        Math.floor(item.version) !== item.version) {
      throw new Error("db.migrateSync: bad version `" + item.version + "`");
    }
    if (done[item.version]) {
      continue;
    }
    var steps = Array.isArray(item.up) ? item.up : [item.up];
    for (var s = 0; s < steps.length; s++) {
      self.execSync(steps[s]);
    }
    self.execSync("INSERT INTO _carne_migrations (version) VALUES (" +
      (self.dialect === "postgres" ? "$1" : "?") + ")", [item.version]);
    applied.push(item.version);
  }
  return applied;
};

/*
 * Defines a model over a table (async CRUD + relations in v1).
 * @param {string} name - Model name.
 * @param {object} opts - {table?, columns} (table defaults to name).
 * @returns {object} The Model (create/find/where/first/all/get).
 */
Database.prototype.defineModel = function (name, opts) {
  reqStr("db.defineModel", "name", name);
  reqObj("db.defineModel", "opts", opts);
  reqObj("db.defineModel", "opts.columns", opts.columns);
  var self = this;
  var table = opts.table === undefined ? name : opts.table;
  reqStr("db.defineModel", "opts.table", table);
  var columns = opts.columns;
  var pk = null;
  var colNames = Object.keys(columns);
  for (var i = 0; i < colNames.length; i++) {
    if (columns[colNames[i]].primaryKey) {
      pk = colNames[i];
      break;
    }
  }
  if (pk === null) {
    throw new Error("db.defineModel: `" + name + "` needs a primaryKey" +
      " column");
  }

  var wrapRef = {f: null};

  function wrap(row) {
    var inst = {__model: null, __pk: pk};
    var keys = Object.keys(row);
    for (var i = 0; i < keys.length; i++) {
      inst[keys[i]] = row[keys[i]];
    }
    inst.__model = model;
    /*
     * Persists field changes (UPDATE by primary key).
     * @returns {Promise<object>} The driver result.
     */
    inst.save = function () {
      var patch = {};
      for (var k = 0; k < keys.length; k++) {
        if (keys[k] !== pk) {
          patch[keys[k]] = inst[keys[k]];
        }
      }
      var eq = {};
      eq[pk] = inst[pk];
      return self.table(table).where(eq).update(patch).run();
    };
    /*
     * Deletes the row by primary key.
     * @returns {Promise<object>} The driver result.
     */
    inst.remove = function () {
      var eq = {};
      eq[pk] = inst[pk];
      return self.table(table).where(eq).delete().run();
    };
    return inst;
  }
  wrapRef.f = wrap;

  /*
   * Wraps one row or null through the current wrapper (relations
   * installed later chain through wrapRef).
   * @param {object|null} row - Driver row.
   * @returns {object|null} The instance or null.
   */
  function W(row) {
    if (row === null || row === undefined) {
      return null;
    }
    return wrapRef.f(row);
  }

  /*
   * Wraps an array of rows.
   * @param {Array} rows - Driver rows.
   * @returns {Array} The instances.
   */
  function Ws(rows) {
    return rows.map(W);
  }

  function mkEq(col, val) {
    var o = {};
    o[col] = val;
    return o;
  }

  var model = {
    name: name,
    table: table,
    columns: columns,
    pk: pk,
    relations: {},
    /*
     * Creates the table from the column definitions.
     * @returns {Promise<object>} The driver result.
     */
    createTable: function () {
      var frags = [];
      for (var i = 0; i < colNames.length; i++) {
        frags.push(columnDDL(self.dialect, colNames[i],
          columns[colNames[i]]));
      }
      return self.exec("CREATE TABLE IF NOT EXISTS " + ident(table) +
        " (" + frags.join(", ") + ")");
    },
    /*
     * Inserts one row, returning the wrapped instance.
     * @param {object} data - Column values.
     * @returns {Promise<object>} The saved instance.
     */
    create: function (data) {
      reqObj("db.create", "data", data);
      return self.table(table).insert(data).run().then(function (r) {
        var out = {};
        var keys = Object.keys(data);
        for (var i = 0; i < keys.length; i++) {
          out[keys[i]] = data[keys[i]];
        }
        if (out[pk] === undefined && r.lastInsertRowId !== undefined) {
          out[pk] = r.lastInsertRowId;
        }
        return W(out);
      });
    },
    /*
     * Finds one row by primary key.
     * @param {any} id - Primary key value.
     * @returns {Promise<object|null>} The instance or null.
     */
    find: function (id) {
      return self.table(table).where(mkEq(pk, id)).first().then(W);
    },
    /*
     * Starts a builder returning wrapped instances.
     * @param {object|string} cond - Where conditions or raw fragment.
     * @param {Array} [params] - Bind values for a raw fragment.
     * @returns {object} {first, all} over wrapped instances.
     */
    where: function (cond, params) {
      var b = params === undefined ?
        self.table(table).where(cond) :
        self.table(table).where(cond, params);
      return {
        first: function () {
          return b.first().then(W);
        },
        all: function () {
          return b.all().then(Ws);
        }
      };
    },
    /*
     * Returns all rows, wrapped.
     * @returns {Promise<Array>} The instances.
     */
    all: function () {
      return self.table(table).all().then(Ws);
    },
    /*
     * Returns the first row, wrapped.
     * @returns {Promise<object|null>} The instance or null.
     */
    first: function () {
      return self.table(table).first().then(W);
    },
    /*
     * Raw passthrough to the table builder.
     * @param {string} t - Ignored (kept for symmetry); table fixed.
     * @returns {QueryBuilder} Unwrapped builder (rows, not instances).
     */
    get: function () {
      return self.table(table);
    },
    /*
     * Declares a one-to-many relation.
     * @param {object} other - Target Model.
     * @param {object} [opts] - {foreignKey?} (default singular + _id).
     * @returns {void} Adds get<Plural>() to instances.
     */
    hasMany: function (other, opts) {
      var fk = opts !== undefined && opts.foreignKey !== undefined ?
        opts.foreignKey : singular(table) + "_id";
      model.relations["many_" + other.name] = {model: other, fk: fk};
      var plural = other.table;
      var getter = "get" + plural.charAt(0).toUpperCase() +
        plural.slice(1);
      var prev = wrapRef.f;
      wrapRef.f = function (row) {
        var inst = prev(row);
        if (inst !== null) {
          inst[getter] = function () {
            var o = {};
            o[fk] = inst[pk];
            return other.where(o).all();
          };
        }
        return inst;
      };
    },
    /*
     * Declares a many-to-one relation.
     * @param {object} other - Target Model.
     * @param {object} [opts] - {foreignKey?} (default singular + _id).
     * @returns {void} Adds get<Model>() to instances.
     */
    belongsTo: function (other, opts) {
      var fk = opts !== undefined && opts.foreignKey !== undefined ?
        opts.foreignKey : singular(other.table) + "_id";
      model.relations["one_" + other.name] = {model: other, fk: fk};
      var getter = "get" + other.name;
      var prev = wrapRef.f;
      wrapRef.f = function (row) {
        var inst = prev(row);
        if (inst !== null) {
          inst[getter] = function () {
            return other.find(inst[fk]);
          };
        }
        return inst;
      };
    }
  };
  return model;
};

/*
 * Connects to a database (async).
 * @param {string|object} spec - "sqlite:PATH", "sqlite::memory:",
 * "postgres://..." or {dialect, path|host, port?, user?, password?,
 * database?, connectTimeout?}.
 * @returns {Promise<Database>} The ORM database.
 */
function connect(spec) {
  arity("db.connect", arguments.length, 1);
  return driver.connect(spec).then(function (handle) {
    return new Database(handle);
  });
}

/*
 * Connects to a database, blocking the loop.
 * @param {string|object} spec - Same shape as connect().
 * @returns {Database} The ORM database.
 */
function connectSync(spec) {
  arity("db.connectSync", arguments.length, 1);
  return new Database(driver.connectSync(spec));
}

module.exports = {
  connect: connect,
  connectSync: connectSync
};
