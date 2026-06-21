import express from 'express';
import session from 'express-session';
import path from 'path';
import { fileURLToPath } from 'url';
import { config } from './config.js';
import { runMigrations } from './db/migrate.js';
import authRoutes from './routes/auth.js';
import apiRoutes from './routes/api.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const app = express();

// Body parsing
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// Session middleware
app.use(
  session({
    secret: config.shopify.apiSecret || 'dev-secret-change-me',
    resave: false,
    saveUninitialized: false,
    cookie: {
      secure: config.isProd,
      httpOnly: true,
      sameSite: 'lax',
      maxAge: 24 * 60 * 60 * 1000, // 24 hours
    },
  })
);

// Health check
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', timestamp: new Date().toISOString() });
});

// Auth routes (OAuth flow)
app.use('/', authRoutes);

// API routes (protected)
app.use('/api', apiRoutes);

// In production, serve the Vite build output
if (config.isProd) {
  const distPath = path.resolve(__dirname, '../../dist');
  app.use(express.static(distPath));

  // SPA fallback — serve index.html for all non-API/auth routes
  app.get('/{*splat}', (_req, res) => {
    res.sendFile(path.join(distPath, 'index.html'));
  });
}

async function start() {
  if (!config.mockMode) {
    // Run database migrations
    try {
      await runMigrations();
    } catch (err) {
      console.error('Migration failed:', err);
      console.warn('Server starting without database. Make sure PostgreSQL is running.');
    }
  } else {
    console.log('Mock mode enabled; skipping database migrations.');
  }

  app.listen(config.port, () => {
    console.log(`Server running on port ${config.port}`);
    console.log(`Environment: ${config.isProd ? 'production' : 'development'}`);
    console.log(`Mode: ${config.mockMode ? 'mock' : 'shopify'}`);
    if (!config.isProd) {
      console.log(`API proxied from Vite at http://localhost:8080`);
    }
  });
}

start();
