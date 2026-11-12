// One-time replica set + user bootstrap. Runs inside mdb-rs-0 (localhost exception). Safe to re-run.
const ns = process.env.POD_NAMESPACE;
const n = parseInt(process.env.RS_MEMBERS, 10);
const host = (i) => `mdb-rs-${i}.mdb-rs-svc.${ns}.svc.cluster.local:27017`;
if (!db.hello().setName) {
  rs.initiate({ _id: "rs0", members: [...Array(n).keys()].map((i) => ({ _id: i, host: host(i), priority: i === 0 ? 2 : 1 })) });
}
while (!db.hello().isWritablePrimary) { sleep(1000); }
const admin = db.getSiblingDB("admin");
let authed = false;
try { authed = admin.auth("mdb-admin", process.env.ADMIN_SECRET).ok === 1; } catch (e) {}
if (!authed) {
  admin.createUser({ user: "mdb-admin", pwd: process.env.ADMIN_SECRET, roles: ["root"] });
  admin.auth("mdb-admin", process.env.ADMIN_SECRET);
}
if (!admin.getUser("search-sync-source")) {
  admin.createUser({ user: "search-sync-source", pwd: process.env.SYNC_SECRET, roles: ["searchCoordinator"] });
}
print("replica set and users ready");
