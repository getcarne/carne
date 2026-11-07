const udp = require("std/udp");

const s = udp.bind(18422, (msg, rinfo) => {
  console.log("server got: " + msg.data + " from " + rinfo.address);
  s.sendTo("pong:" + msg.data, rinfo);
});

const c = udp.connect("127.0.0.1", 18422, (msg) => {
  console.log("client got: " + msg.data);
  c.close();
  s.close();
});
c.send("ping");
