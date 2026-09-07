import { config, assertConfigured } from './config.js';
import { log } from './log.js';
import { createApp } from './app.js';
import { seedDemoData } from './seed.js';

assertConfigured();

if (config.seedDemo) {
  seedDemoData({ password: process.env.SEED_PASSWORD ?? 'flyabove' });
}

const server = createApp().listen(config.port, '0.0.0.0', () => {
  log.info('Flycom API elindult', {
    port: config.port,
    livekit: config.livekit.url,
    production: config.isProduction,
    database: config.databasePath,
  });
});

/// Finish the requests already in flight before exiting.
///
/// A restart during a broadcast should not drop a token request that was one
/// millisecond from being answered.
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    log.info('leállítás', { signal });
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(1), 10_000).unref();
  });
}
