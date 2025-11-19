/**
 * Redis Cache Middleware for Pelias API
 * Provides intelligent caching for geocoding queries
 */

const redis = require('redis');
const crypto = require('crypto');

class PeliasCache {
  constructor(config = {}) {
    this.config = {
      host: config.host || process.env.REDIS_HOST || 'localhost',
      port: config.port || process.env.REDIS_PORT || 6379,
      password: config.password || process.env.REDIS_PASSWORD,
      db: config.db || 0,
      keyPrefix: config.keyPrefix || 'pelias:',
      enabled: config.enabled !== false,
      // TTL configs (in seconds)
      ttl: {
        search: config.ttl?.search || 3600,           // 1 hour for address searches
        reverse: config.ttl?.reverse || 7200,         // 2 hours for reverse geocoding
        autocomplete: config.ttl?.autocomplete || 1800, // 30 min for autocomplete
        structured: config.ttl?.structured || 3600,    // 1 hour for structured search
        admin: config.ttl?.admin || 86400,            // 24 hours for admin areas
        postalcode: config.ttl?.postalcode || 86400   // 24 hours for postal codes
      }
    };

    if (this.config.enabled) {
      this.client = redis.createClient({
        host: this.config.host,
        port: this.config.port,
        password: this.config.password,
        db: this.config.db,
        retry_strategy: (options) => {
          if (options.error && options.error.code === 'ECONNREFUSED') {
            console.error('Redis connection refused');
            return new Error('Redis server refused connection');
          }
          if (options.total_retry_time > 1000 * 60 * 60) {
            return new Error('Redis retry time exhausted');
          }
          if (options.attempt > 10) {
            return undefined;
          }
          return Math.min(options.attempt * 100, 3000);
        }
      });

      this.client.on('error', (err) => {
        console.error('Redis Client Error', err);
      });

      this.client.on('connect', () => {
        console.log('Redis cache connected successfully');
      });
    } else {
      console.log('Redis cache disabled');
    }
  }

  /**
   * Generate cache key from request
   */
  generateKey(endpoint, params) {
    const sortedParams = Object.keys(params)
      .sort()
      .reduce((acc, key) => {
        acc[key] = params[key];
        return acc;
      }, {});

    const keyString = `${endpoint}:${JSON.stringify(sortedParams)}`;
    const hash = crypto.createHash('md5').update(keyString).digest('hex');
    return `${this.config.keyPrefix}${endpoint}:${hash}`;
  }

  /**
   * Determine TTL based on endpoint and query type
   */
  getTTL(endpoint, params) {
    // Admin-only queries get longer cache
    if (params.layers && ['locality', 'region', 'country'].includes(params.layers)) {
      return this.config.ttl.admin;
    }

    // Postal code queries get longer cache
    if (params.postalcode || (params.text && /^\d{5}(-\d{4})?$/.test(params.text))) {
      return this.config.ttl.postalcode;
    }

    // Endpoint-specific TTL
    switch (endpoint) {
      case 'search':
        return this.config.ttl.search;
      case 'reverse':
        return this.config.ttl.reverse;
      case 'autocomplete':
        return this.config.ttl.autocomplete;
      case 'structured':
        return this.config.ttl.structured;
      default:
        return this.config.ttl.search;
    }
  }

  /**
   * Check if request should be cached
   */
  shouldCache(endpoint, params) {
    if (!this.config.enabled) return false;

    // Don't cache requests with focus.point (user-specific)
    if (params['focus.point.lat'] || params['focus.point.lon']) {
      return false;
    }

    // Don't cache very large size requests
    if (params.size && parseInt(params.size) > 50) {
      return false;
    }

    return true;
  }

  /**
   * Get cached response
   */
  async get(endpoint, params) {
    if (!this.shouldCache(endpoint, params)) {
      return null;
    }

    const key = this.generateKey(endpoint, params);

    return new Promise((resolve, reject) => {
      this.client.get(key, (err, data) => {
        if (err) {
          console.error('Redis GET error:', err);
          resolve(null);
        } else if (data) {
          try {
            const parsed = JSON.parse(data);
            console.log(`Cache HIT: ${endpoint} - ${key.substring(0, 50)}...`);
            resolve(parsed);
          } catch (parseErr) {
            console.error('Cache parse error:', parseErr);
            resolve(null);
          }
        } else {
          console.log(`Cache MISS: ${endpoint}`);
          resolve(null);
        }
      });
    });
  }

  /**
   * Set cached response
   */
  async set(endpoint, params, data) {
    if (!this.shouldCache(endpoint, params)) {
      return false;
    }

    const key = this.generateKey(endpoint, params);
    const ttl = this.getTTL(endpoint, params);

    return new Promise((resolve, reject) => {
      this.client.setex(key, ttl, JSON.stringify(data), (err) => {
        if (err) {
          console.error('Redis SET error:', err);
          resolve(false);
        } else {
          console.log(`Cache SET: ${endpoint} (TTL: ${ttl}s)`);
          resolve(true);
        }
      });
    });
  }

  /**
   * Clear cache for specific pattern
   */
  async clear(pattern = '*') {
    const fullPattern = `${this.config.keyPrefix}${pattern}`;

    return new Promise((resolve, reject) => {
      this.client.keys(fullPattern, (err, keys) => {
        if (err) {
          reject(err);
        } else if (keys.length > 0) {
          this.client.del(keys, (delErr, count) => {
            if (delErr) {
              reject(delErr);
            } else {
              console.log(`Cleared ${count} cache entries`);
              resolve(count);
            }
          });
        } else {
          resolve(0);
        }
      });
    });
  }

  /**
   * Get cache statistics
   */
  async stats() {
    return new Promise((resolve, reject) => {
      this.client.info('stats', (err, info) => {
        if (err) {
          reject(err);
        } else {
          // Parse Redis INFO output
          const stats = {};
          info.split('\r\n').forEach(line => {
            const parts = line.split(':');
            if (parts.length === 2) {
              stats[parts[0]] = parts[1];
            }
          });
          resolve(stats);
        }
      });
    });
  }

  /**
   * Express middleware
   */
  middleware() {
    return async (req, res, next) => {
      if (!this.config.enabled) {
        return next();
      }

      // Extract endpoint from path
      const endpoint = req.path.split('/').pop();
      const params = { ...req.query, ...req.params };

      // Try to get from cache
      const cachedResponse = await this.get(endpoint, params);

      if (cachedResponse) {
        // Add cache header
        res.set('X-Cache', 'HIT');
        res.set('X-Cache-Key', this.generateKey(endpoint, params).substring(0, 32));
        return res.json(cachedResponse);
      }

      // Store original res.json
      const originalJson = res.json.bind(res);

      // Override res.json to cache response
      res.json = async (data) => {
        res.set('X-Cache', 'MISS');

        // Cache the response asynchronously
        this.set(endpoint, params, data).catch(err => {
          console.error('Failed to cache response:', err);
        });

        return originalJson(data);
      };

      next();
    };
  }

  /**
   * Close Redis connection
   */
  close() {
    if (this.client) {
      this.client.quit();
    }
  }
}

module.exports = PeliasCache;

// Example usage:
// const PeliasCache = require('./redis-cache-middleware');
// const cache = new PeliasCache({ host: 'localhost', port: 6379 });
// app.use('/v1', cache.middleware());
