const tcp = require("std/tcp");

const srv = tcp.serve(18421, {
  onOpen: (c) => console.log("open " + c.remoteAddress),
  onData: (c, chunk) => c.write("echo:" + chunk)
});

let done;
const gate = new Promise((r) => { done = r; });
(async () => {
  const c = await tcp.connect("127.0.0.1", 18421, {
    onData: (chunk) => {
      console.log("got: " + chunk);
      c.close();
      tcp.close(srv.port);
      done(true);
    }
  });
  console.log("peer: " + c.remoteAddress + ":" + c.remotePort);
  c.write("hello");
})();
gate;
