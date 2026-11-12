const env = require("std/env");
const os = require("std/os");

const parsed = env.parse([
  "# demo env",
  "APP_NAME=carne",
  "APP_PORT=8080",
  'GREETING="hello $APP_NAME on $APP_PORT"',
  "RAW='no $expansion here'",
  "export SHARED=yes",
  ""
].join("\n"));

console.log("parsed GREETING: " + parsed.GREETING);
console.log("parsed RAW: " + parsed.RAW);
console.log("stringify: " + JSON.stringify(env.stringify({A: "1", B: "x y"})));
console.log("roundtrip B: " + env.parse(env.stringify({B: "x y"})).B);

const tmp = "/tmp/carne_dotenv_demo";
os.writeFile(tmp, "CARNE_DEMO_LOADED=it-works\n");
env.load(tmp);
console.log("loaded into env: " + env.getEnv("CARNE_DEMO_LOADED"));
os.remove(tmp);

env.putEnv("CARNE_DEMO_DIRECT", "yes");
console.log("direct putEnv: " + env.getEnv("CARNE_DEMO_DIRECT"));
console.log("hasEnv: " + env.hasEnv("CARNE_DEMO_DIRECT"));
env.delEnv("CARNE_DEMO_DIRECT");
console.log("after delEnv: " + env.hasEnv("CARNE_DEMO_DIRECT"));
