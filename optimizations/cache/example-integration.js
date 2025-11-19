/**
 * Example: How to integrate Redis cache with Pelias API
 */

const express = require('express');
const PeliasCache = require('./redis-cache-middleware');

const app = express();

// Initialize cache
const cache = new PeliasCache({
  host: process.env.REDIS_HOST || 'localhost',
  port: process.env.REDIS_PORT || 6379,
  enabled: process.env.CACHE_ENABLED !== 'false',
  ttl: {
    search: 3600,           // 1 hour
    reverse: 7200,          // 2 hours
    autocomplete: 1800,     // 30 minutes
    structured: 3600,       // 1 hour
    admin: 86400,           // 24 hours
    postalcode: 86400       // 24 hours
  }
});

// Apply cache middleware to all v1 endpoints
app.use('/v1', cache.middleware());

// Your existing Pelias API routes
app.get('/v1/search', async (req, res) => {
  // Your search logic here
  // If cached, the middleware will return early
  // If not cached, this will execute and result will be cached

  const results = await performSearch(req.query);
  res.json(results);
});

app.get('/v1/reverse', async (req, res) => {
  const results = await performReverse(req.query);
  res.json(results);
});

app.get('/v1/autocomplete', async (req, res) => {
  const results = await performAutocomplete(req.query);
  res.json(results);
});

app.get('/v1/search/structured', async (req, res) => {
  const results = await performStructuredSearch(req.query);
  res.json(results);
});

// Cache management endpoints
app.post('/admin/cache/clear', async (req, res) => {
  try {
    const pattern = req.query.pattern || '*';
    const count = await cache.clear(pattern);
    res.json({ success: true, cleared: count });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.get('/admin/cache/stats', async (req, res) => {
  try {
    const stats = await cache.stats();
    res.json(stats);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Graceful shutdown
process.on('SIGTERM', () => {
  console.log('SIGTERM received, closing cache...');
  cache.close();
  process.exit(0);
});

// Mock functions (replace with actual Pelias logic)
async function performSearch(params) {
  // Your Elasticsearch query logic
  return { type: 'FeatureCollection', features: [] };
}

async function performReverse(params) {
  return { type: 'FeatureCollection', features: [] };
}

async function performAutocomplete(params) {
  return { type: 'FeatureCollection', features: [] };
}

async function performStructuredSearch(params) {
  return { type: 'FeatureCollection', features: [] };
}

const PORT = process.env.PORT || 4000;
app.listen(PORT, () => {
  console.log(`Pelias API with cache listening on port ${PORT}`);
});

module.exports = app;
