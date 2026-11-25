import { createApp, files, lakebase, server } from '@databricks/appkit';
import { setupReviewRoutes } from './routes/review-routes';

createApp({
  plugins: [
    // Trader documents in the UC volume are read-only for the app.
    files({ volumes: { files: { policy: files.policy.publicRead() } } }),
    lakebase(),
    server(),
  ],
  async onPluginsReady(appkit) {
    await setupReviewRoutes(appkit);
  },
}).catch(console.error);
