const watcher = require("std/watcher");
const os = require("std/os");

const path = os.tmpdir() + "/carne-watcher-demo.txt";
os.writeFile(path, "start\n");

const w = watcher.watch(path, (events) => {
  console.log("events: " + events.join(","));
  w.close();
});
setTimeout(() => { os.appendFile(path, "more\n"); }, 50);

// Sync form blocks until the next event batch (or timeout).
// const events = watcher.watchOnce(path, 2000);
// console.log("once: " + events.join(","));
