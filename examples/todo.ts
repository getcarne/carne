// Typed todo CLI for carne: `carne run examples/todo.ts add "buy milk"`
// Uses only require() (CommonJS): ESM import/export stays rejected.
const os = require("std/os");

interface Task {
  id: number;
  title: string;
  done?: boolean;
}

const DB = os.tmpdir() + "/carne_todo_demo.json";

function load(): Task[] {
  if (!os.exists(DB)) {
    return [];
  }
  const raw = os.readFile(DB) as string;
  return JSON.parse(raw) as Task[];
}

function save(tasks: Task[]): void {
  os.writeFile(DB, JSON.stringify(tasks));
}

function nextId(tasks: Task[]): number {
  let top = 0;
  for (const t of tasks) {
    if (t.id > top) {
      top = t.id;
    }
  }
  return top + 1;
}

function cmdList(tasks: Task[]): void {
  for (const t of tasks) {
    console.log((t.done ? "[x] " : "[ ] ") + t.id + ": " + t.title);
  }
  if (tasks.length === 0) {
    console.log("(empty)");
  }
}

const argv: string[] = process.argv.slice(2) as string[];
const cmd: string = argv[0] ?? "list";
const tasks: Task[] = load();

if (cmd === "add") {
  const title = argv.slice(1).join(" ");
  if (title === "") {
    console.log("usage: todo.ts add <title>");
  } else {
    tasks.push({ id: nextId(tasks), title: title });
    save(tasks);
    console.log("added #" + tasks[tasks.length - 1].id);
  }
} else if (cmd === "done") {
  const id = parseInt(argv[1] ?? "", 10);
  const t = tasks.find((x: Task) => x.id === id);
  if (t === undefined) {
    console.log("no such task: " + argv[1]);
  } else {
    t.done = true;
    save(tasks);
    console.log("done #" + id);
  }
} else if (cmd === "reset") {
  save([]);
  console.log("reset");
} else {
  cmdList(tasks);
}
