const archive = require("std/archive");
const os = require("std/os");

// one-shot compression: strings in, Uint8Array out
const compressed = archive.compress("gz", "hello world, ".repeat(100));
console.log("compressed: " + compressed.length + " bytes");
const back = archive.decompress("gz", compressed);
console.log("roundtrip: " + (back.length === 1300));

// build a tar.gz in memory, persist it, inspect it
const blob = archive.create("tar", [
  {name: "hello.txt", data: "hello archive"},
  {name: "data/", dir: true},
  {name: "data/bytes.bin", data: new Uint8Array([0, 1, 255, 128])},
], {compression: "gz"});
os.writeFileBytes("/tmp/carne_demo.tar.gz", blob);
console.log("identify: " + JSON.stringify(archive.identify("/tmp/carne_demo.tar.gz")));
console.log("entries: " + JSON.stringify(archive.list("/tmp/carne_demo.tar.gz")));

// read contents back without touching disk
for (const e of archive.read("/tmp/carne_demo.tar.gz"))
  console.log("read: " + e.name + " (" + e.data.length + " bytes)");

// whole trees, the same way
os.mkdir("/tmp/carne_demo_tree", true);
os.writeFile("/tmp/carne_demo_tree/a.txt", "alpha");
archive.archiveDir("tar", "/tmp/carne_demo_tree", "/tmp/carne_demo_tree.tar");
archive.extract("/tmp/carne_demo_tree.tar", "/tmp/carne_demo_restored");
console.log("restored: " + os.readFile("/tmp/carne_demo_restored/carne_demo_tree/a.txt"));
