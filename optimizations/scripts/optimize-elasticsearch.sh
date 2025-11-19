#!/bin/bash

##############################################################################
# Elasticsearch Optimization Script for Pelias
# This script applies performance optimizations to an existing ES cluster
##############################################################################

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
ES_HOST="${ES_HOST:-localhost:9200}"
INDEX_NAME="${INDEX_NAME:-pelias}"

echo -e "${GREEN}=== Pelias Elasticsearch Optimization Script ===${NC}"
echo "Target: $ES_HOST"
echo "Index: $INDEX_NAME"
echo ""

# Check if Elasticsearch is running
echo -e "${YELLOW}[1/8] Checking Elasticsearch connectivity...${NC}"
if ! curl -sf "http://$ES_HOST/_cluster/health" > /dev/null; then
    echo -e "${RED}ERROR: Cannot connect to Elasticsearch at $ES_HOST${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Connected to Elasticsearch${NC}"
echo ""

# Get cluster stats
echo -e "${YELLOW}[2/8] Getting cluster statistics...${NC}"
CLUSTER_STATS=$(curl -sf "http://$ES_HOST/_cluster/stats?human&pretty")
echo "$CLUSTER_STATS" | grep -E "(heap_used|count|size)" | head -10
echo ""

# Optimize index settings
echo -e "${YELLOW}[3/8] Optimizing index settings...${NC}"
curl -sf -XPUT "http://$ES_HOST/$INDEX_NAME/_settings" -H 'Content-Type: application/json' -d '{
  "index": {
    "refresh_interval": "30s",
    "number_of_replicas": 1,
    "max_result_window": 10000,
    "codec": "best_compression",
    "query": {
      "default_field": "name.default"
    },
    "translog": {
      "durability": "async",
      "sync_interval": "30s",
      "flush_threshold_size": "512mb"
    },
    "merge": {
      "scheduler": {
        "max_thread_count": 1
      }
    }
  }
}' | jq .
echo -e "${GREEN}✓ Index settings optimized${NC}"
echo ""

# Force merge (optimize index)
echo -e "${YELLOW}[4/8] Force merging index segments...${NC}"
echo "This may take a while for large indices..."
curl -sf -XPOST "http://$ES_HOST/$INDEX_NAME/_forcemerge?max_num_segments=1" | jq .
echo -e "${GREEN}✓ Force merge completed${NC}"
echo ""

# Clear field data cache
echo -e "${YELLOW}[5/8] Clearing field data cache...${NC}"
curl -sf -XPOST "http://$ES_HOST/$INDEX_NAME/_cache/clear?fielddata=true" | jq .
echo -e "${GREEN}✓ Field data cache cleared${NC}"
echo ""

# Clear query cache
echo -e "${YELLOW}[6/8] Clearing query cache...${NC}"
curl -sf -XPOST "http://$ES_HOST/$INDEX_NAME/_cache/clear?query=true" | jq .
echo -e "${GREEN}✓ Query cache cleared${NC}"
echo ""

# Update cluster settings for better performance
echo -e "${YELLOW}[7/8] Updating cluster settings...${NC}"
curl -sf -XPUT "http://$ES_HOST/_cluster/settings" -H 'Content-Type: application/json' -d '{
  "persistent": {
    "indices.memory.index_buffer_size": "30%",
    "indices.queries.cache.size": "10%",
    "indices.fielddata.cache.size": "20%",
    "thread_pool.write.queue_size": 1000,
    "thread_pool.search.queue_size": 1000,
    "cluster.routing.allocation.disk.watermark.low": "85%",
    "cluster.routing.allocation.disk.watermark.high": "90%",
    "cluster.routing.allocation.disk.watermark.flood_stage": "95%"
  }
}' | jq .
echo -e "${GREEN}✓ Cluster settings updated${NC}"
echo ""

# Display index statistics
echo -e "${YELLOW}[8/8] Final index statistics...${NC}"
curl -sf "http://$ES_HOST/$INDEX_NAME/_stats?human&pretty" | grep -E "(total|size|count)" | head -15
echo ""

# Recommendations
echo -e "${GREEN}=== Optimization Complete! ===${NC}"
echo ""
echo -e "${YELLOW}Additional Recommendations:${NC}"
echo "1. Monitor heap usage: curl $ES_HOST/_cat/nodes?v&h=heap.percent,ram.percent"
echo "2. Check slow queries: curl $ES_HOST/_cat/thread_pool?v&h=name,queue,rejected"
echo "3. Monitor cache hit rates via API metrics"
echo "4. Consider scaling horizontally if heap > 75% consistently"
echo ""
echo -e "${GREEN}Run this script periodically (weekly) for best performance.${NC}"
