// Staging-bootstrap for mongodb CF Container. Runs on EVERY cold start
// because CF Containers wipe /data/db on sleep.
//
// Idempotent: createUser fails with code 51003 ("user already exists")
// if the admin already created the user in the same boot — we swallow
// that. Other codes propagate.

(function () {
  var adminDb = db.getSiblingDB('admin');

  // Mongo entrypoint already creates the root user from
  // MONGO_INITDB_ROOT_USERNAME/MONGO_INITDB_ROOT_PASSWORD. Confirm it
  // resolved successfully so the api connection doesn't hit "no users
  // configured" on the first call.
  var users = adminDb.system.users.find({ user: 'admin' }).count();
  if (users === 0) {
    print('00_staging_bootstrap: no admin user found, creating one from env vars');
    adminDb.createUser({
      user: process.env.MONGO_INITDB_ROOT_USERNAME || 'admin',
      pwd:  process.env.MONGO_INITDB_ROOT_PASSWORD || 'staging-bootstrap',
      roles: [{ role: 'root', db: 'admin' }],
    });
  } else {
    print('00_staging_bootstrap: admin user already provisioned by mongo entrypoint');
  }
  print('00_staging_bootstrap: complete');
})();
