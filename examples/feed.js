const feed = require("std/feed");

const rss = feed.parseRss(
  '<?xml version="1.0"?>' +
  '<rss version="2.0"><channel>' +
  '<title>Demo Blog</title>' +
  '<link>http://blog.example</link>' +
  '<description>Posts and updates</description>' +
  '<item><title>First post</title><link>http://blog.example/1</link>' +
  '<pubDate>Tue, 03 Jan 2026 00:00:00 GMT</pubDate></item>' +
  '<item><title>Second post</title><link>http://blog.example/2</link></item>' +
  '</channel></rss>');

console.log("rss: " + rss.title + " (" + rss.items.length + " items)");
console.log("latest: " + rss.items[0].title + " -> " + rss.items[0].link);

const atom = feed.parseAtom(
  '<?xml version="1.0"?>' +
  '<feed xmlns="http://www.w3.org/2005/Atom">' +
  '<id>urn:demo</id><title>Demo Feed</title>' +
  '<updated>2026-01-01T00:00:00Z</updated>' +
  '<author><name>Ann</name></author>' +
  '<entry><id>urn:demo:1</id><title>Hello Atom</title>' +
  '<updated>2026-01-02T00:00:00Z</updated>' +
  '<link href="http://blog.example/a1"/></entry>' +
  '</feed>');

console.log("atom: " + atom.title.value + " by " + atom.authors[0].name);
console.log("entry link: " + atom.entries[0].links[0].href);

console.log("rss roundtrip: " + feed.parseRss(feed.stringifyRss(rss)).title);
console.log("atom roundtrip: " + feed.parseAtom(feed.stringifyAtom(atom)).id);
